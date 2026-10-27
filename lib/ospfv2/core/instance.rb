# frozen_string_literal: true

require_relative '../infra/event_loop'
require_relative 'addr'
require_relative 'lsa'
require_relative 'lsdb'
require_relative 'wire'
require_relative 'neighbor'
require_relative 'interface'
require_relative 'area'

module OSPFv2
  module Core
    # One OSPFv2 router: areas, interfaces, flooding (RFC 2328 section 13),
    # LSA origination and aging (sections 12 and 14).
    #
    #   loop = EventLoop.new.start
    #   r = Instance.new(router_id: '1.1.1.1', loop: loop)
    #   r.add_interface(name: 'eth1', address: '10.0.12.1/24', area: 0,
    #                   transport: Transport::RawSocket.new('10.0.12.1', interface: 'eth1'))
    #   loop.call { r.start }
    #
    # Every method runs on the loop thread. From another thread, wrap
    # calls in loop.call { ... }.
    class Instance
      Event = Struct.new(:time, :level, :interface, :message) do
        def to_s = "#{time.strftime('%H:%M:%S')} #{interface ? "#{interface} " : ''}#{message}"
      end

      MAX_EVENTS = 2000
      AS_SCOPE = [5].freeze
      AREA_SCOPE = [1, 2, 3, 4].freeze

      attr_reader :router_id, :loop, :areas, :interfaces, :as_lsdb, :random, :events, :stats

      # router_id: dotted quad or Integer
      # loop:      the EventLoop that owns this router
      # logger:    optional ->(level, message) for every event
      # tracer:    optional ->(direction, interface, packet, peer) per packet
      def initialize(router_id:, loop:, random: Random.new, logger: nil, tracer: nil)
        @router_id = Addr.to_i(router_id)
        @loop = loop
        @random = random
        @logger = logger
        @tracer = tracer
        @areas = {}
        @interfaces = {}
        @as_lsdb = Lsdb.new(loop.clock)
        @own = {}
        @events = []
        @stats = Hash.new(0)
        @listeners = []
        @running = false
      end

      def router_id_s = Addr.to_s(@router_id)

      def area(id)
        id = Addr.to_i(id.is_a?(Integer) ? id : id.to_s)
        @areas[id] ||= Area.new(self, id)
      end

      def add_interface(name:, address:, area: 0, transport: nil, **opts)
        raise ArgumentError, "interface #{name} already exists" if @interfaces.key?(name)
        a = self.area(area)
        iface = Interface.new(self, name: name, address: address, area: a, transport: transport, **opts)
        a.interfaces << iface
        @interfaces[name] = iface
        iface.up if @running
        iface
      end

      def start
        return self if @running
        @running = true
        log(:info, nil, "router #{router_id_s} starting")
        @interfaces.each_value(&:up)
        @sweep = @loop.every(1, :maxage_sweep) { sweep }
        self
      end

      def stop
        return self unless @running
        @running = false
        @interfaces.each_value(&:down)
        @sweep&.cancel
        @own.each_value { |o| o[:refresh]&.cancel; o[:deferred]&.cancel }
        log(:info, nil, "router #{router_id_s} stopped")
        self
      end

      def running? = @running

      # Called with (neighbor, old_state, new_state) on every change.
      def on_neighbor_change(&block)
        @listeners << block
        self
      end

      # ---- scopes ----

      def lsdb_for(type, area)
        return @as_lsdb if AS_SCOPE.include?(type)
        return area.lsdb if AREA_SCOPE.include?(type)
        nil
      end

      def lsdbs_for(area)
        [area.lsdb, @as_lsdb]
      end

      def scope_interfaces(type, area)
        AS_SCOPE.include?(type) ? @interfaces.values : area.interfaces
      end

      # ---- hooks from interfaces and neighbors ----

      def neighbor_changed(nbr, old, new)
        nbr.iface.forget(nbr) if new == :down
        nbr.iface.area.schedule_origination if old == :full || new == :full
        @listeners.each { |l| l.call(nbr, old, new) }
      end

      def interface_changed(iface, _old, _new)
        iface.area.schedule_origination
      end

      def dr_changed(iface)
        iface.area.schedule_origination
      end

      # ---- receiving updates (RFC 2328 13) ----

      def receive_update(nbr, lsu)
        return unless nbr.at_least?(:exchange)
        iface = nbr.iface
        area = iface.area
        lsu.lsas.each do |lsa|
          unless lsa.checksum_ok?
            iface.drop(:lsa, "bad checksum on #{lsa.id_string} from #{nbr}")
            next
          end
          db = lsdb_for(lsa.type, area)
          unless db
            iface.drop(:lsa, "unsupported type #{lsa.type} from #{nbr}")
            next
          end
          cur = db[lsa.key]

          # (4) A MaxAge LSA we do not have, with nobody mid-exchange.
          if lsa.max_age? && cur.nil? && !exchanging?(lsa.type, area)
            iface.direct_ack(lsa, nbr)
            next
          end

          if cur.nil? || lsa.newer_than?(cur)
            # (5a) Too soon after the last one.
            next if cur && db.since_installed(lsa.key) < OSPFv2::MinLSArrival && lsa.advr != @router_id

            flooded_back = flood(lsa, area, from: nbr)
            drop_old_retransmits(lsa, area)
            db.install(lsa)
            @stats[:lsa_installed] += 1
            unless flooded_back
              iface.delayed_ack(lsa) if !iface.backup? || nbr.address == iface.dr
            end
            self_originated(lsa, area) if self_originated?(lsa)
          elsif nbr.ls_request.key?(lsa.key)
            nbr.bad_ls_req("#{lsa.id_string} is not newer than ours")
            return
          elsif lsa.same_instance?(cur)
            if nbr.retransmitting?(lsa.key)
              nbr.remove_retransmit(lsa.key) # implied ack
              iface.delayed_ack(lsa) if iface.backup? && nbr.address == iface.dr
            else
              iface.direct_ack(lsa, nbr)
            end
          else
            # (8) Ours is newer: send it back, but never a MaxSequenceNumber flush.
            next if cur.max_age? && cur.seq == LsaFields::MAX_SEQ
            iface.send_update([cur], nbr.address)
          end
        end
      end

      # ---- flooding (RFC 2328 13.3) ----

      # Floods +lsa+ out of every interface in its scope. +from+ is the
      # neighbor it came from, or nil when we originated it. Returns true
      # when it went back out of the receiving interface.
      def flood(lsa, area, from: nil)
        flooded_back = false
        scope_interfaces(lsa.type, area).each do |iface|
          next unless iface.up? && !iface.passive?
          added = false
          iface.neighbors.values.each do |n|
            next unless n.at_least?(:exchange)
            if (req = n.ls_request[lsa.key])
              cmp = lsa.compare(req)
              next if cmp.negative?
              n.request_satisfied(lsa.key)
              next if cmp.zero?
            end
            next if n.equal?(from)
            n.add_retransmit(lsa)
            added = true
          end
          next unless added
          if from && iface.equal?(from.iface)
            next if from.address == iface.dr || from.address == iface.bdr
            next if iface.backup?
            flooded_back = true
          end
          iface.send_update([lsa], iface.flood_destination)
        end
        flooded_back
      end

      # ---- origination (RFC 2328 12.4) ----

      # Originates the LSA described by +spec+ ({type:, ls_id:, body:}) if
      # it differs from what we have. Honors MinLSInterval.
      def originate(area, spec, force: false)
        key = [spec[:type], spec[:ls_id], @router_id]
        db = lsdb_for(spec[:type], area)
        cur = db[key]
        own = @own[key]
        unchanged = own && cur && !cur.max_age? && cur.body == spec[:body]
        return if unchanged && !force

        if own && (wait = own[:last_at] + OSPFv2::MinLSInterval - @loop.now).positive?
          own[:deferred] ||= @loop.after(wait, :min_ls_interval) do
            own[:deferred] = nil
            s = area.spec_for(key)
            s ? originate(area, s, force: true) : flush_own(area, key)
          end
          return
        end

        if cur && cur.seq == LsaFields::MAX_SEQ
          # Sequence space exhausted: flush, start over once it is gone.
          flush_own(area, key)
          @own[key] = { area: area, last_at: @loop.now, wrap: true }
          return
        end

        seq = cur ? cur.seq + 1 : LsaFields::INITIAL_SEQ
        lsa = Lsa.build(type: spec[:type], ls_id: spec[:ls_id], advr: @router_id, seq: seq,
                        body: spec[:body], options: 0x02)
        install_own(area, lsa)
      end

      # Flushes our LSA +key+ from +area+ (premature aging, RFC 2328 14.1).
      def flush_own(area, key)
        o = @own.delete(key)
        o&.[](:refresh)&.cancel
        o&.[](:deferred)&.cancel
        db = lsdb_for(key[0], area)
        cur = db[key]
        return unless cur && !cur.max_age?
        flush(cur, area)
      end

      # ---- show ----

      def neighbors
        @interfaces.values.flat_map { |i| i.neighbors.values }
      end

      def neighbor_summaries
        neighbors.map(&:summary)
      end

      def interface_summaries
        @interfaces.values.map(&:summary)
      end

      # Every LSA we hold, with its area (nil for AS scope).
      def database
        rows = @areas.values.flat_map { |a| a.lsdb.map { |l| [a, l] } }
        rows + @as_lsdb.map { |l| [nil, l] }
      end

      # ---- log ----

      def log(level, iface, message)
        ev = Event.new(@loop.clock.wall, level, iface&.name, message)
        @events << ev
        @events.shift(@events.size - MAX_EVENTS) if @events.size > MAX_EVENTS
        @logger&.call(level, ev.to_s)
      end

      def trace(dir, iface, pkt, peer)
        @tracer&.call(dir, iface.name, pkt, peer)
      end

      private

      def install_own(area, lsa)
        db = lsdb_for(lsa.type, area)
        db.install(lsa)
        @stats[:lsa_originated] += 1
        o = (@own[lsa.key] ||= { area: area })
        o[:last_at] = @loop.now
        o.delete(:wrap)
        o[:refresh] ||= @loop.every(OSPFv2::LSRefreshTime, :ls_refresh, start: false) do
          s = area.spec_for(lsa.key)
          s ? originate(area, s, force: true) : flush_own(area, lsa.key)
        end
        o[:refresh].restart
        log(:debug, nil, "originated #{lsa}")
        drop_old_retransmits(lsa, area)
        flood(lsa, area)
      end

      def flush(cur, area)
        lsa = cur.with_age(OSPFv2::MaxAge)
        lsdb_for(lsa.type, area).install(lsa)
        log(:info, nil, "flushing #{lsa.id_string}")
        drop_old_retransmits(lsa, area)
        flood(lsa, area)
      end

      # RFC 2328 13.4: one of our own LSAs came back newer than ours.
      def self_originated(lsa, area)
        key = lsa.key
        if lsa.advr == @router_id && area.wants?(key) && !@own.dig(key, :wrap)
          # Jump past the sequence number that came back, now rather than
          # after MinLSInterval.
          o = (@own[key] ||= { area: area })
          o[:deferred]&.cancel
          o[:deferred] = nil
          o[:last_at] = -Float::INFINITY
          originate(area, area.spec_for(key), force: true)
        elsif !lsa.max_age?
          flush(lsa, area)
        end
      end

      def self_originated?(lsa)
        lsa.advr == @router_id || (lsa.type == 2 && @interfaces.each_value.any? { |i| i.address == lsa.ls_id })
      end

      def exchanging?(type, area)
        scope_interfaces(type, area).any? do |i|
          i.neighbors.each_value.any? { |n| %i[exchange loading].include?(n.state) }
        end
      end

      # RFC 2328 13 (5c): older instances of this LSA leave every
      # retransmission list.
      def drop_old_retransmits(lsa, area)
        scope_interfaces(lsa.type, area).each do |i|
          i.neighbors.each_value do |n|
            old = n.retransmit[lsa.key]
            n.remove_retransmit(lsa.key) if old && !old.same_instance?(lsa)
          end
        end
      end

      # RFC 2328 14: reflood LSAs that aged out, and remove MaxAge LSAs
      # once nobody needs them.
      def sweep
        sweep_db(@as_lsdb, @areas.values.first) if @areas.any?
        @areas.each_value { |a| sweep_db(a.lsdb, a) }
      end

      def sweep_db(db, area)
        db.max_age_entries.each do |e|
          key = e.key
          if e.lsa.age < OSPFv2::MaxAge && !e.aged_out
            e.aged_out = true
            log(:info, nil, "#{e.lsa.id_string} reached MaxAge")
            flood(db.current(e), area)
          end
          next if exchanging?(key[0], area)
          next if scope_interfaces(key[0], area).any? { |i| i.neighbors.each_value.any? { |n| n.retransmitting?(key) } }
          db.delete(key)
          if (o = @own[key]) && o[:wrap]
            @own.delete(key)
            spec = area.spec_for(key)
            originate(area, spec) if spec
          end
        end
      end
    end
  end
end
