# frozen_string_literal: true

require_relative 'wire'
require_relative 'auth'
require_relative 'neighbor'

module OSPFv2
  module Core
    # One OSPF interface: hellos, the RFC 2328 section 9 state machine,
    # DR/BDR election and the neighbors on the segment.
    #
    # Runs on the event loop thread only.
    class Interface
      STATES = %i[down loopback waiting point_to_point dr_other backup dr].freeze
      TYPES = %i[broadcast p2p].freeze

      DEFAULTS = {
        type: :broadcast, cost: 10, priority: 1, hello_interval: 10, dead_interval: nil,
        rxmt_interval: 5, transmit_delay: 1, mtu: 1500, mtu_ignore: false, passive: false, auth: nil
      }.freeze

      attr_reader :instance, :name, :area, :address, :prefix_len, :type, :cost, :priority,
                  :hello_interval, :dead_interval, :rxmt_interval, :transmit_delay, :mtu,
                  :state, :dr, :bdr, :neighbors, :stats, :transport, :auth
      attr_accessor :mtu_ignore

      # instance:  the Core::Instance
      # name:      interface name ("eth1")
      # address:   "10.0.0.1/24"
      # area:      the Core::Area
      # transport: a Transport (RawSocket, Loopback); nil for passive
      # auth:      authentication spec for Auth.build (null by default)
      def initialize(instance, name:, address:, area:, transport: nil, **opts)
        unknown = opts.keys - DEFAULTS.keys
        raise ArgumentError, "unknown interface option(s): #{unknown.join(', ')}" unless unknown.empty?
        o = DEFAULTS.merge(opts)
        raise ArgumentError, "interface type must be one of #{TYPES.join(', ')}" unless TYPES.include?(o[:type])
        raise ArgumentError, 'priority must be 0..255' unless o[:priority].between?(0, 255)
        raise ArgumentError, 'cost must be 1..65535' unless o[:cost].between?(1, 65_535)
        raise ArgumentError, 'hello interval must be 1..65535' unless o[:hello_interval].between?(1, 65_535)

        @instance = instance
        @name = name
        @area = area
        @address, @prefix_len = Addr.parse_prefix(address)
        @type = o[:type]
        @cost = o[:cost]
        @priority = o[:priority]
        @hello_interval = o[:hello_interval]
        @dead_interval = o[:dead_interval] || 4 * @hello_interval
        @rxmt_interval = o[:rxmt_interval]
        @transmit_delay = o[:transmit_delay]
        @mtu = o[:mtu]
        @mtu_ignore = o[:mtu_ignore]
        @passive = o[:passive]
        self.auth = o[:auth]
        @transport = transport
        raise ArgumentError, "interface #{name} needs a transport unless passive" if @transport.nil? && !@passive

        @state = :down
        @dr = 0
        @bdr = 0
        @neighbors = {}
        @delayed_acks = []
        @crypto_seqs = {} # router id => highest cryptographic sequence number accepted
        @stats = Hash.new(0)
      end

      def loop = @instance.loop

      # Replaces the authentication (Auth.build spec or object). Takes
      # effect on the next packet sent or received.
      def auth=(spec)
        clock = -> { @instance.loop.clock.wall.to_i }
        # One sequence for the life of the interface: a new key or a new
        # Auth object must never send a lower number than the last one.
        @auth_sequence ||= Auth::Sequence.new(clock)
        @auth = Auth.build(spec, clock: clock, sequence: @auth_sequence)
      end

      # Changes the cost without touching adjacencies; the router-LSA is
      # originated again.
      def cost=(value)
        raise ArgumentError, 'cost must be 1..65535' unless value.is_a?(Integer) && value.between?(1, 65_535)
        return if value == @cost
        @cost = value
        @area.schedule_origination if up?
      end

      # Largest packet body that fits the MTU with our authentication.
      def max_body = Wire.max_body(@mtu, @auth.trailer_size)
      def broadcast? = @type == :broadcast
      def p2p? = @type == :p2p
      def passive? = @passive
      def up? = @state != :down
      def virtual? = false

      # Where hellos go; a virtual link sends them to the other end.
      def hello_destination = AllSPFRouters

      def mask = Addr.mask(@prefix_len)
      def network = @address & mask

      # E bit: we take AS-external LSAs. Stub areas come in Phase 3.
      # E bit unless the area is a stub (RFC 2328 A.2).
      def options = @area.options

      def dr? = @state == :dr
      def backup? = @state == :backup

      # ---- interface events (RFC 2328 9.2, 9.3) ----

      def up
        return if up?
        @transport&.start { |bytes, from| loop.offer { receive(bytes, from) } }
        if @passive
          change(:point_to_point, 'InterfaceUp (passive)') if p2p?
          change(:dr_other, 'InterfaceUp (passive)') if broadcast?
          return
        end
        @hello_timer ||= loop.every(@hello_interval, :hello, jitter: 0.1, start: false) { send_hello }
        if p2p?
          change(:point_to_point, 'InterfaceUp')
        elsif @priority.zero?
          change(:dr_other, 'InterfaceUp')
        else
          change(:waiting, 'InterfaceUp')
          @wait_timer = loop.after(@dead_interval, :wait) { wait_timer }
        end
        send_hello
        @hello_timer.restart
      end

      def down
        return unless up?
        [@hello_timer, @wait_timer, @ack_timer].each { |t| t&.cancel }
        # No elections or packets while the interface goes away (RFC 2328 9.3).
        @going_down = true
        @neighbors.values.each { |n| n.kill('InterfaceDown') }
        @going_down = false
        @neighbors.clear
        @crypto_seqs.clear
        @delayed_acks.clear
        @dr = @bdr = 0
        @transport&.stop
        change(:down, 'InterfaceDown')
      end

      # NeighborChange (RFC 2328 9.2).
      def neighbor_change
        return if @going_down
        elect('NeighborChange') if %i[dr_other backup dr].include?(@state)
      end

      # Should we be adjacent with +nbr+ (RFC 2328 10.4)?
      def adjacency_ok?(nbr)
        return true if p2p?
        dr? || backup? || nbr.address == @dr || nbr.address == @bdr
      end

      def full_neighbors
        @neighbors.values.select(&:full?)
      end

      # A neighbor reached Down: forget it.
      def forget(nbr)
        @neighbors.delete(neighbor_key(nbr.router_id, nbr.address)) if @neighbors.values.include?(nbr)
        @crypto_seqs.delete(nbr.router_id) unless @neighbors.each_value.any? { |n| n.router_id == nbr.router_id }
      end

      # ---- receive (RFC 2328 8.2) ----

      def receive(bytes, from)
        return unless up?
        from_i = Addr.to_i(from)
        # Checks that cost nothing come before any hash is computed.
        hdr = Wire.peek(bytes)
        name = Wire::NAMES.fetch(hdr.type, :packet)
        @stats[:"rx_#{name}"] += 1
        unless hdr.area_id == @area.id
          # Backbone packets on a non-backbone interface are for a virtual
          # link through this area (RFC 2328 8.2).
          return @instance.virtual_receive(bytes, from, self) if hdr.area_id.zero? && !@area.id.zero?
          return drop(name, "area #{Addr.to_s(hdr.area_id)} from #{from}, ours is #{Addr.to_s(@area.id)}")
        end
        return drop(name, "router id #{Addr.to_s(hdr.router_id)} from #{from} is ours") if hdr.router_id == @instance.router_id
        return drop(name, "source #{from} not on #{Addr.to_s(network)}/#{@prefix_len}") if broadcast? && (from_i & mask) != network
        # On a LAN a neighbor is its address. A packet from that address
        # with another router id is a replay, a spoof or a renumbered
        # router; the real neighbor's state stays untouched either way.
        if broadcast? && (at = @neighbors[from_i]) && at.router_id != hdr.router_id
          return drop(name, "router id #{Addr.to_s(hdr.router_id)} from #{from}, where neighbor #{at} is")
        end

        pkt = Wire.decode(bytes, auth: @auth)
        key = neighbor_key(pkt.router_id, from_i)
        return if pkt.crypto_seq && replayed?(pkt, from)

        if pkt.type == Wire::HELLO
          receive_hello(pkt, from_i)
        else
          nbr = @neighbors[key]
          return drop(pkt.name, "from unknown neighbor #{Addr.to_s(pkt.router_id)}@#{from}") unless nbr
          trace(:rx, pkt, from)
          case pkt.type
          when Wire::DD  then nbr.receive_dd(pkt.body)
          when Wire::LSR then nbr.receive_ls_request(pkt.body)
          when Wire::LSU then @instance.receive_update(nbr, pkt.body)
          when Wire::ACK then nbr.receive_ack(pkt.body)
          end
        end
        record_crypto_seq(pkt) if pkt.crypto_seq
      rescue Wire::AuthError => e
        drop(:auth, "from #{from}: #{e.message}")
      rescue Wire::Error => e
        drop(:packet, "from #{from}: #{e.message}")
      end

      def drop(kind, reason)
        @stats[:"drop_#{kind}"] += 1
        @instance.log(:warn, self, "dropped #{kind}: #{reason}", kind: :drop, what: kind.to_s, reason: reason.to_s)
        nil
      end

      # ---- send ----

      def send_packet(body, dest)
        return unless @transport && up? && !@going_down
        bytes = Wire.encode(body, router_id: @instance.router_id, area_id: @area.id, auth: @auth)
        @stats[:"tx_#{Wire::NAMES[body.class.type]}"] += 1
        trace(:tx, body, Addr.to_s(dest.is_a?(Integer) ? dest : Addr.to_i(dest)))
        @transport.send_packet(bytes, dest.is_a?(Integer) ? Addr.to_s(dest) : dest)
      end

      # Sends LSAs in as many updates as the MTU needs. Ages grow by
      # InfTransDelay on the way out (RFC 2328 13.3).
      def send_update(lsas, dest)
        aged = lsas.map { |l| l.with_age(l.age + @transmit_delay) }
        room = max_body
        Wire.batches(aged, room, fixed: 4, &:length).each do |batch|
          send_packet(Wire::LinkStateUpdate.new(lsas: batch), dest)
        end
      end

      # Where updates and delayed acks go on this interface.
      def flood_destination
        return AllSPFRouters if p2p? || dr? || backup?
        AllDRouters
      end

      def delayed_ack(header)
        @delayed_acks << header
        @ack_timer ||= loop.timer([@rxmt_interval / 2.0, 1].min, :delayed_ack) { flush_acks }
        @ack_timer.restart unless @ack_timer.active?
      end

      def direct_ack(header, nbr)
        send_acks([header], nbr.unicast_destination)
      end

      def summary
        {
          name: @name, address: "#{Addr.to_s(@address)}/#{@prefix_len}", area: Addr.to_s(@area.id),
          type: @type, state: @state, cost: @cost, priority: @priority, passive: @passive,
          dr: Addr.to_s(@dr), bdr: Addr.to_s(@bdr), hello_interval: @hello_interval,
          dead_interval: @dead_interval, rxmt_interval: @rxmt_interval, mtu: @mtu, auth: @auth.to_s,
          neighbors: @neighbors.size, adjacent: full_neighbors.size,
          hello_due: @hello_timer&.remaining&.round(1)
        }
      end

      private

      def neighbor_key(router_id, address)
        p2p? ? router_id : address
      end

      # RFC 2328 D.5.2: the cryptographic sequence number from a neighbor
      # never goes down. A lower one is a replay. The highest number is
      # kept per router id, not per address, so a packet replayed from
      # another source address is caught too. As the RFC allows, an equal
      # number passes: the newest packet can be replayed until the next
      # one arrives (RFC 7474 closes that; not implemented).
      def replayed?(pkt, from)
        last = @crypto_seqs[pkt.router_id]
        return false unless last && pkt.crypto_seq < last
        drop(:auth, "from #{from}: sequence #{pkt.crypto_seq} below #{last} from #{Addr.to_s(pkt.router_id)}, replayed?")
        true
      end

      # Remembers the sequence number once the packet was accepted and
      # its router id is a neighbor.
      def record_crypto_seq(pkt)
        rid = pkt.router_id
        return unless @neighbors.each_value.any? { |n| n.router_id == rid }
        last = @crypto_seqs[rid]
        @crypto_seqs[rid] = pkt.crypto_seq if last.nil? || pkt.crypto_seq > last
      end

      def change(new_state, event)
        old = @state
        return if old == new_state
        @state = new_state
        @instance.log(:info, self, "interface #{@name}: #{old} -> #{new_state} (#{event})",
                      kind: :interface, from: old.to_s, to: new_state.to_s, event: event.to_s)
        @instance.interface_changed(self, old, new_state)
      end

      # ---- hello (RFC 2328 9.5, 10.5) ----

      def send_hello
        nbrs = @neighbors.values.select { |n| n.at_least?(:init) }.map(&:router_id)
        hello = Wire::Hello.new(netmask: mask, hello_interval: @hello_interval, options: options,
                                priority: @priority, dead_interval: @dead_interval,
                                dr: @dr, bdr: @bdr, neighbors: nbrs)
        send_packet(hello, hello_destination)
      end

      def receive_hello(pkt, from)
        h = pkt.body
        rid = pkt.router_id
        return drop(:hello, "netmask #{Addr.to_s(h.netmask)} from #{Addr.to_s(from)}, ours is #{Addr.to_s(mask)}") if broadcast? && h.netmask != mask
        return drop(:hello, "hello interval #{h.hello_interval} from #{Addr.to_s(from)}, ours is #{@hello_interval}") if h.hello_interval != @hello_interval
        return drop(:hello, "dead interval #{h.dead_interval} from #{Addr.to_s(from)}, ours is #{@dead_interval}") if h.dead_interval != @dead_interval
        return drop(:hello, "E bit mismatch from #{Addr.to_s(from)}") if (h.options & 0x02) != (options & 0x02)
        return drop(:hello, "N bit mismatch from #{Addr.to_s(from)}") if (h.options & 0x08) != (options & 0x08)

        key = neighbor_key(rid, from)
        nbr = @neighbors[key]
        if nbr.nil?
          # One router id, one neighbor: a hello claiming a router id we
          # already know at another address is a replay or a duplicate id.
          if broadcast? && (other = @neighbors.each_value.find { |n| n.router_id == rid })
            return drop(:hello, "router id #{Addr.to_s(rid)} from #{Addr.to_s(from)} is already neighbor #{other}")
          end
          nbr = @neighbors[key] = Neighbor.new(self, router_id: rid, address: from)
          @instance.log(:info, self, "new neighbor #{nbr}", kind: :neighbor, router_id: Addr.to_s(rid),
                                                            address: Addr.to_s(from), from: nil, to: 'new', event: 'hello')
        end
        old_pri = nbr.priority
        was_dr = nbr.declares_dr?
        was_bdr = nbr.declares_bdr?
        nbr.update_from_hello(h, router_id: rid, address: from)

        nbr.hello_received
        if h.neighbors.include?(@instance.router_id)
          nbr.two_way_received
        else
          nbr.one_way_received
          return
        end

        neighbor_change if nbr.priority != old_pri
        if @state == :waiting && ((nbr.declares_dr? && nbr.bdr.zero?) || nbr.declares_bdr?)
          backup_seen
        elsif nbr.declares_dr? != was_dr || nbr.declares_bdr? != was_bdr
          neighbor_change
        end
      end

      def wait_timer
        elect('WaitTimer') if @state == :waiting
      end

      def backup_seen
        @wait_timer&.cancel
        elect('BackupSeen')
      end

      # ---- DR election (RFC 2328 9.4) ----

      Candidate = Struct.new(:router_id, :address, :priority, :dr, :bdr) do
        def declares_dr? = dr == address
        def declares_bdr? = bdr == address
        def rank = [priority, router_id]
      end

      def elect(event)
        @wait_timer&.cancel
        old_dr = @dr
        old_bdr = @bdr
        me = Candidate.new(@instance.router_id, @address, @priority, @dr, @bdr)
        others = @neighbors.values.select { |n| n.at_least?(:two_way) && n.priority.positive? }
                           .map { |n| Candidate.new(n.router_id, n.address, n.priority, n.dr, n.bdr) }

        dr, bdr = elect_once(me, others)
        was = [me.declares_dr?, me.declares_bdr?]
        now_is = [dr == @address, bdr == @address]
        if was != now_is
          me.dr = dr
          me.bdr = bdr
          dr, bdr = elect_once(me, others)
        end
        @dr = dr
        @bdr = bdr

        new_state = if @dr == @address then :dr
                    elsif @bdr == @address then :backup
                    else :dr_other
                    end
        change(new_state, event)
        if @dr != old_dr || @bdr != old_bdr
          @instance.log(:info, self, "interface #{@name}: DR #{Addr.to_s(@dr)} BDR #{Addr.to_s(@bdr)}",
                        kind: :dr, dr: Addr.to_s(@dr), bdr: Addr.to_s(@bdr))
          @neighbors.values.each { |n| n.adj_ok if n.at_least?(:two_way) }
          @instance.dr_changed(self)
        end
      end

      def elect_once(me, others)
        cands = (me.priority.positive? ? [me] : []) + others
        # Step 2: BDR, among those not declaring themselves DR.
        pool = cands.reject(&:declares_dr?)
        declared = pool.select(&:declares_bdr?)
        bdr = (declared.empty? ? pool : declared).max_by(&:rank)
        # Step 3: DR.
        declared_dr = cands.select(&:declares_dr?)
        dr = declared_dr.empty? ? bdr : declared_dr.max_by(&:rank)
        [dr&.address || 0, bdr&.address || 0]
      end

      # ---- acks (RFC 2328 13.5) ----

      def flush_acks
        return if @delayed_acks.empty?
        acks = @delayed_acks.uniq
        @delayed_acks.clear
        send_acks(acks, flood_destination)
      end

      def send_acks(headers, dest)
        room = max_body
        Wire.batches(headers, room) { LsaHeader::SIZE }.each do |batch|
          send_packet(Wire::LinkStateAck.new(headers: batch.map(&:header)), dest)
        end
      end

      def trace(dir, pkt, peer)
        @instance.trace(dir, self, pkt, peer)
      end
    end
  end
end
