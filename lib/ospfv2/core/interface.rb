# frozen_string_literal: true

require_relative 'wire'
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
        rxmt_interval: 5, transmit_delay: 1, mtu: 1500, mtu_ignore: false, passive: false
      }.freeze

      attr_reader :instance, :name, :area, :address, :prefix_len, :type, :cost, :priority,
                  :hello_interval, :dead_interval, :rxmt_interval, :transmit_delay, :mtu,
                  :state, :dr, :bdr, :neighbors, :stats, :transport
      attr_accessor :mtu_ignore

      # instance:  the Core::Instance
      # name:      interface name ("eth1")
      # address:   "10.0.0.1/24"
      # area:      the Core::Area
      # transport: a Transport (RawSocket, Loopback); nil for passive
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
        @transport = transport
        raise ArgumentError, "interface #{name} needs a transport unless passive" if @transport.nil? && !@passive

        @state = :down
        @dr = 0
        @bdr = 0
        @neighbors = {}
        @delayed_acks = []
        @stats = Hash.new(0)
      end

      def loop = @instance.loop
      def broadcast? = @type == :broadcast
      def p2p? = @type == :p2p
      def passive? = @passive
      def up? = @state != :down

      def mask = Addr.mask(@prefix_len)
      def network = @address & mask

      # E bit: we take AS-external LSAs. Stub areas come in Phase 3.
      def options = 0x02

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
      end

      # ---- receive (RFC 2328 8.2) ----

      def receive(bytes, from)
        return unless up?
        from_i = Addr.to_i(from)
        pkt = Wire.decode(bytes)
        @stats[:"rx_#{pkt.name}"] += 1
        return drop(pkt.name, "area #{Addr.to_s(pkt.area_id)} from #{from}, ours is #{Addr.to_s(@area.id)}") unless pkt.area_id == @area.id
        return drop(pkt.name, "router id #{Addr.to_s(pkt.router_id)} from #{from} is ours") if pkt.router_id == @instance.router_id
        return drop(pkt.name, "source #{from} not on #{Addr.to_s(network)}/#{@prefix_len}") if broadcast? && (from_i & mask) != network

        if pkt.type == Wire::HELLO
          receive_hello(pkt, from_i)
          return
        end

        nbr = @neighbors[neighbor_key(pkt.router_id, from_i)]
        return drop(pkt.name, "from unknown neighbor #{Addr.to_s(pkt.router_id)}@#{from}") unless nbr
        trace(:rx, pkt, from)
        case pkt.type
        when Wire::DD  then nbr.receive_dd(pkt.body)
        when Wire::LSR then nbr.receive_ls_request(pkt.body)
        when Wire::LSU then @instance.receive_update(nbr, pkt.body)
        when Wire::ACK then nbr.receive_ack(pkt.body)
        end
      rescue Wire::Error => e
        drop(:packet, "from #{from}: #{e.message}")
      end

      def drop(kind, reason)
        @stats[:"drop_#{kind}"] += 1
        @instance.log(:warn, self, "dropped #{kind}: #{reason}")
        nil
      end

      # ---- send ----

      def send_packet(body, dest)
        return unless @transport && up? && !@going_down
        bytes = Wire.encode(body, router_id: @instance.router_id, area_id: @area.id)
        @stats[:"tx_#{Wire::NAMES[body.class.type]}"] += 1
        trace(:tx, body, Addr.to_s(dest.is_a?(Integer) ? dest : Addr.to_i(dest)))
        @transport.send_packet(bytes, dest.is_a?(Integer) ? Addr.to_s(dest) : dest)
      end

      # Sends LSAs in as many updates as the MTU needs. Ages grow by
      # InfTransDelay on the way out (RFC 2328 13.3).
      def send_update(lsas, dest)
        aged = lsas.map { |l| l.with_age(l.age + @transmit_delay) }
        room = Wire.max_body(@mtu)
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
          dead_interval: @dead_interval, rxmt_interval: @rxmt_interval, mtu: @mtu,
          neighbors: @neighbors.size, adjacent: full_neighbors.size,
          hello_due: @hello_timer&.remaining&.round(1)
        }
      end

      private

      def neighbor_key(router_id, address)
        p2p? ? router_id : address
      end

      def change(new_state, event)
        old = @state
        return if old == new_state
        @state = new_state
        @instance.log(:info, self, "interface #{@name}: #{old} -> #{new_state} (#{event})")
        @instance.interface_changed(self, old, new_state)
      end

      # ---- hello (RFC 2328 9.5, 10.5) ----

      def send_hello
        nbrs = @neighbors.values.select { |n| n.at_least?(:init) }.map(&:router_id)
        hello = Wire::Hello.new(netmask: mask, hello_interval: @hello_interval, options: options,
                                priority: @priority, dead_interval: @dead_interval,
                                dr: @dr, bdr: @bdr, neighbors: nbrs)
        send_packet(hello, AllSPFRouters)
      end

      def receive_hello(pkt, from)
        h = pkt.body
        rid = pkt.router_id
        return drop(:hello, "netmask #{Addr.to_s(h.netmask)} from #{Addr.to_s(from)}, ours is #{Addr.to_s(mask)}") if broadcast? && h.netmask != mask
        return drop(:hello, "hello interval #{h.hello_interval} from #{Addr.to_s(from)}, ours is #{@hello_interval}") if h.hello_interval != @hello_interval
        return drop(:hello, "dead interval #{h.dead_interval} from #{Addr.to_s(from)}, ours is #{@dead_interval}") if h.dead_interval != @dead_interval
        return drop(:hello, "E bit mismatch from #{Addr.to_s(from)}") if (h.options & 0x02) != (options & 0x02)

        key = neighbor_key(rid, from)
        nbr = @neighbors[key]
        if nbr.nil?
          nbr = @neighbors[key] = Neighbor.new(self, router_id: rid, address: from)
          @instance.log(:info, self, "new neighbor #{nbr}")
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
          @instance.log(:info, self, "interface #{@name}: DR #{Addr.to_s(@dr)} BDR #{Addr.to_s(@bdr)}")
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
        room = Wire.max_body(@mtu)
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
