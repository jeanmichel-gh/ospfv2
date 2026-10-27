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
        @own = {}              # key => { area:, refresh:, wrap: } for LSAs we originate
        @last_origination = {} # key => loop time, for MinLSInterval (kept across flushes)
        @deferred = {}         # key => timer for an origination held by MinLSInterval
        @sent_back = {}        # key => loop time we last answered a stale copy
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
        begin
          iface.up if @running
        rescue StandardError
          # The transport would not start: leave no trace of the interface.
          @interfaces.delete(name)
          a.interfaces.delete(iface)
          drop_area(a) if a.interfaces.empty?
          raise
        end
        iface
      end

      # Takes interface +name+ down and forgets it. Our network-LSA for it,
      # if we were DR, is flushed, and the router-LSA no longer lists it.
      def remove_interface(name)
        iface = @interfaces.delete(name) or return nil
        was_dr = iface.dr?
        iface.down
        area = iface.area
        area.interfaces.delete(iface)
        flush_own(area, [2, iface.address, @router_id]) if was_dr
        if area.interfaces.empty?
          drop_area(area)
        elsif @running
          area.schedule_origination
        end
        log(:info, iface, "interface #{name} removed")
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

      # Stops the router. With +flush+, our LSAs are first flooded at
      # MaxAge (RFC 2328 14.1), so neighbors drop them now rather than an
      # hour later. Used when the router id changes.
      def stop(flush: false)
        return self unless @running
        if flush
          @own.to_a.each { |key, o| flush_own(o[:area], key) if @areas[o[:area].id].equal?(o[:area]) }
        end
        @running = false
        @interfaces.each_value(&:down)
        @sweep&.cancel
        @own.each_value { |o| o[:refresh]&.cancel }
        @deferred.each_value(&:cancel)
        @deferred.clear
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
            # (8) Ours is newer: send it back, at most once per MinLSArrival,
            # and never a MaxSequenceNumber flush.
            next if cur.max_age? && cur.seq == LsaFields::MAX_SEQ
            last = @sent_back[lsa.key]
            next if last && @loop.now - last < OSPFv2::MinLSArrival
            @sent_back[lsa.key] = @loop.now
            iface.send_update([cur], nbr.unicast_destination)
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
        return unless @running
        key = [spec[:type], spec[:ls_id], @router_id]
        db = lsdb_for(spec[:type], area)
        cur = db[key]
        unchanged = @own[key] && cur && !cur.max_age? && cur.body == spec[:body]
        return if unchanged && !force

        last = @last_origination[key]
        if last && (wait = last + OSPFv2::MinLSInterval - @loop.now).positive?
          @deferred[key] ||= @loop.after(wait, :min_ls_interval) do
            @deferred.delete(key)
            s = area.spec_for(key)
            s ? originate(area, s, force: true) : flush_own(area, key)
          end
          return
        end

        if cur && cur.seq == LsaFields::MAX_SEQ
          # Sequence space exhausted: flush, start over once it is gone.
          flush_own(area, key)
          @own[key] = { area: area, wrap: true }
          return
        end

        seq = cur ? cur.seq + 1 : LsaFields::INITIAL_SEQ
        lsa = Lsa.build(type: spec[:type], ls_id: spec[:ls_id], advr: @router_id, seq: seq,
                        body: spec[:body], options: 0x02)
        install_own(area, lsa)
      end

      # Flushes our LSA +key+ from +area+ (premature aging, RFC 2328 14.1).
      def flush_own(area, key)
        return unless @running
        @own.delete(key)&.[](:refresh)&.cancel
        @deferred.delete(key)&.cancel
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
        record(level, message, iface)
        @logger&.call(level, iface ? "#{iface.name} #{message}" : message)
      end

      # Adds an event to the list without passing it to the logger.
      def record(level, message, iface = nil)
        ev = Event.new(@loop.clock.wall, level, iface&.name, message)
        @events << ev
        @events.shift(@events.size - MAX_EVENTS) if @events.size > MAX_EVENTS
        ev
      end

      def trace(dir, iface, pkt, peer)
        @tracer&.call(dir, iface.name, pkt, peer)
      end

      private

      # An area with no interfaces left: stop refreshing our LSAs in it and
      # forget it.
      def drop_area(area)
        @own.select { |_, o| o[:area].equal?(area) }.each_key do |key|
          @own.delete(key)[:refresh]&.cancel
          @deferred.delete(key)&.cancel
        end
        @areas.delete(area.id)
      end

      def install_own(area, lsa)
        db = lsdb_for(lsa.type, area)
        db.install(lsa)
        @stats[:lsa_originated] += 1
        o = (@own[lsa.key] ||= { area: area })
        @last_origination[lsa.key] = @loop.now
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
        # A flush is a new instance too: the next origination waits
        # MinLSInterval, or routers two hops away drop it (13 step 5a).
        @last_origination[lsa.key] = @loop.now if lsa.advr == @router_id
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
          @own[key] ||= { area: area }
          @deferred.delete(key)&.cancel
          @last_origination.delete(key)
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
