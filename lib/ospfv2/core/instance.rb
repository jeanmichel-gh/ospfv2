# frozen_string_literal: true

require_relative '../infra/event_loop'
require_relative 'addr'
require_relative 'lsa'
require_relative 'lsdb'
require_relative 'wire'
require_relative 'neighbor'
require_relative 'interface'
require_relative 'area'
require_relative 'spf'
require_relative 'spf_scheduler'

module OSPFv2
  module Core
    # One OSPFv2 router: areas, interfaces, flooding (RFC 2328 section 13),
    # LSA origination and aging (sections 12 and 14), and the routing
    # table (section 16), recomputed with RFC 8405 back-off.
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
      MAX_SPF_LOG = 100

      # One SPF run, for show ospf log and show ip ospf statistics.
      SpfRun = Struct.new(:time, :reasons, :duration, :routes, :diff, keyword_init: true)
      AS_SCOPE = [5].freeze
      AREA_SCOPE = [1, 2, 3, 4, 7].freeze

      attr_reader :router_id, :loop, :areas, :interfaces, :as_lsdb, :random, :events, :stats,
                  :route_table, :spf, :spf_log, :externals
      # area id => { stub: { default_metric:, no_summaries: } }
      attr_accessor :area_options

      # router_id: dotted quad or Integer
      # loop:      the EventLoop that owns this router
      # logger:    optional ->(level, message) for every event
      # tracer:    optional ->(direction, interface, packet, peer) per packet
      # spf:       RFC 8405 timers in seconds, see SpfScheduler::DEFAULTS
      # max_paths: equal-cost next hops kept per route
      def initialize(router_id:, loop:, random: Random.new, logger: nil, tracer: nil, spf: {}, max_paths: 16)
        @router_id = Addr.to_i(router_id)
        @loop = loop
        @random = random
        @logger = logger
        @tracer = tracer
        @areas = {}
        @interfaces = {}
        @as_lsdb = Lsdb.new(loop.clock)
        @as_lsdb.on_change = method(:lsdb_changed)
        @max_paths = max_paths
        @route_table = Spf::Table.empty
        @spf_log = []
        @externals = {} # key => spec, the AS-external-LSAs we originate
        @exported = []  # the external routes we were given to advertise
        @area_options = {}
        @spf_skipped = []
        @route_listeners = []
        @spf = SpfScheduler.new(loop, **spf) { |reasons| compute_routes(reasons) }
        # Keyed by scope_key: our router-LSA is one LSA key in every area,
        # but a separate LSA in each.
        @own = {}              # scope key => { area:, key:, refresh:, wrap: } for LSAs we originate
        @last_origination = {} # scope key => loop time, for MinLSInterval (kept across flushes)
        @deferred = {}         # scope key => timer for an origination held by MinLSInterval
        @sent_back = {}        # scope key => loop time we last answered a stale copy
        @events = []
        @stats = Hash.new(0)
        @listeners = []
        @running = false
      end

      def router_id_s = Addr.to_s(@router_id)

      def area(id)
        id = Addr.to_i(id.is_a?(Integer) ? id : id.to_s)
        @areas[id] ||= Area.new(self, id).tap { |a| a.lsdb.on_change = method(:lsdb_changed) }
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
        @spf.trigger(:interface, name) if @running
        log(:info, iface, "interface #{name} removed")
        iface
      end

      def start
        return self if @running
        @running = true
        log(:info, nil, "router #{router_id_s} starting")
        @interfaces.each_value(&:up)
        refresh_externals
        @sweep = @loop.every(1, :maxage_sweep) { sweep }
        self
      end

      # Stops the router. With +flush+, our LSAs are first flooded at
      # MaxAge (RFC 2328 14.1), so neighbors drop them now rather than an
      # hour later. Used when the router id changes.
      def stop(flush: false)
        return self unless @running
        if flush
          @own.to_a.each do |sk, o|
            # AS-wide LSAs flood the same from any area.
            flush_own(o[:area], o[:key]) if sk[0].nil? || @areas[o[:area].id].equal?(o[:area])
          end
        end
        @running = false
        @interfaces.each_value(&:down)
        @sweep&.cancel
        @own.each_value { |o| o[:refresh]&.cancel }
        @deferred.each_value(&:cancel)
        @deferred.clear
        @spf.stop
        # Nothing routes through a stopped router.
        replace_routes(Spf::Table.empty, [SpfScheduler::Reason.new(:stop, nil)], 0.0) unless @route_table.routes.empty?
        log(:info, nil, "router #{router_id_s} stopped")
        self
      end

      def running? = @running

      # Called with (neighbor, old_state, new_state) on every change.
      def on_neighbor_change(&block)
        @listeners << block
        self
      end

      # Called with an Spf::Diff each time the routing table changes.
      # The FIB hangs off this.
      def on_route_change(&block)
        @route_listeners << block
        self
      end

      def off_route_change(block)
        @route_listeners.delete(block)
        self
      end

      # Routes as { [prefix, len] => Spf::Route }.
      def routes = @route_table.routes

      # ---- scopes ----

      # The database for LSA +type+ in +area+; nil if none (externals in a
      # stub area, RFC 2328 3.6).
      def lsdb_for(type, area)
        return (area&.external_capable? == false ? nil : @as_lsdb) if AS_SCOPE.include?(type)
        return (area.nssa? ? area.lsdb : nil) if type == 7
        return area.lsdb if AREA_SCOPE.include?(type)
        nil
      end

      def lsdbs_for(area)
        area.external_capable? ? [area.lsdb, @as_lsdb] : [area.lsdb]
      end

      def scope_interfaces(type, area)
        AS_SCOPE.include?(type) ? @interfaces.values.select { |i| i.area.external_capable? } : area.interfaces
      end

      # ---- hooks from interfaces and neighbors ----

      def neighbor_changed(nbr, old, new)
        nbr.iface.forget(nbr) if new == :down
        if old == :full || new == :full
          nbr.iface.area.schedule_origination
          @spf.trigger(:neighbor, Addr.to_s(nbr.router_id))
        end
        @listeners.each { |l| l.call(nbr, old, new) }
      end

      def interface_changed(iface, old, new)
        iface.area.schedule_origination
        return unless old == :down || new == :down
        # Up or down can make us an area border router or stop it: every
        # router-LSA carries the B bit.
        @areas.each_value(&:schedule_origination)
        refresh_externals if new != :down
        @spf.trigger(:interface, iface.name)
      end

      # Attached to more than one area (RFC 2328 3.3): an area border router.
      def abr? = @areas.values.count(&:active?) > 1

      # Advertising external routes (ours or translated): an AS boundary router.
      def asbr? = !@externals.empty?

      # Bringing routes of our own into OSPF.
      def exporting? = !@exported.empty?

      # ---- AS-external-LSAs (RFC 2328 12.4.4) ----

      # Sets the external routes we advertise:
      #   [{ prefix:, prefix_len:, metric:, type: 1|2, tag: }]
      # New and changed ones are originated, the rest flushed. The E bit
      # goes on or off in every router-LSA as the list fills or empties.
      def externals=(routes)
        @exported = routes.map(&:dup)
        refresh_externals
      end

      # Works out every external LSA we should have: type 5 for our routes
      # and for type 7 routes we translate, type 7 into each NSSA (RFC 3101)
      # for our routes and the NSSA default. Originates what changed,
      # flushes what went.
      def refresh_externals(table = @route_table)
        was = [asbr?, exporting?]
        specs = external_specs(5, @exported + translations(table), nil)
        old = @externals
        @externals = specs
        originate_externals
        area = @areas.values.find(&:external_capable?)
        (old.keys - specs.keys).each { |key| flush_own(area, key) } if area
        @areas.each_value do |a|
          a.nssa_lsas = a.nssa? && a.active? ? nssa_specs(a) : {}
        end
        @areas.each_value(&:schedule_origination) if [asbr?, exporting?] != was
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
            why = case lsa.type
                  when *AS_SCOPE then 'AS-external LSA in a stub area or NSSA'
                  when 7 then 'type 7 LSA outside an NSSA'
                  else "unsupported type #{lsa.type}"
                  end
            iface.drop(:lsa, "#{why} from #{nbr}")
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
            sk = scope_key(area, lsa.key)
            last = @sent_back[sk]
            next if last && @loop.now - last < OSPFv2::MinLSArrival
            @sent_back[sk] = @loop.now
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
        sk = scope_key(area, key)
        db = lsdb_for(spec[:type], area)
        cur = db[key]
        options = spec[:options] || (AS_SCOPE.include?(spec[:type]) ? 0x02 : area.lsa_options)
        unchanged = @own[sk] && cur && !cur.max_age? && cur.body == spec[:body] && cur.options == options
        return if unchanged && !force

        last = @last_origination[sk]
        if last && (wait = last + OSPFv2::MinLSInterval - @loop.now).positive?
          @deferred[sk] ||= @loop.after(wait, :min_ls_interval) do
            @deferred.delete(sk)
            s = area.spec_for(key)
            s ? originate(area, s, force: true) : flush_own(area, key)
          end
          return
        end

        if cur && cur.seq == LsaFields::MAX_SEQ
          # Sequence space exhausted: flush, start over once it is gone.
          flush_own(area, key)
          @own[sk] = { area: area, key: key, wrap: true }
          return
        end

        seq = cur ? cur.seq + 1 : LsaFields::INITIAL_SEQ
        lsa = Lsa.build(type: spec[:type], ls_id: spec[:ls_id], advr: @router_id, seq: seq,
                        body: spec[:body], options: options)
        install_own(area, lsa)
      end

      # Flushes our LSA +key+ from +area+ (premature aging, RFC 2328 14.1).
      def flush_own(area, key)
        return unless @running
        sk = scope_key(area, key)
        @own.delete(sk)&.[](:refresh)&.cancel
        @deferred.delete(sk)&.cancel
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

      # ---- routing table (RFC 2328 16) ----

      # Runs the calculation over every database and swaps the new table
      # in. Called by the SPF scheduler.
      def compute_routes(reasons = [])
        return unless @running
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        table = Spf.run(router_id: @router_id, areas: spf_areas, externals: @as_lsdb.live, max_paths: @max_paths)
        @stats[:spf_runs] += 1
        replace_routes(table, reasons, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)
        originate_summaries(table)
        refresh_externals(table)
        # Warn once per bad LSA, not on every run.
        (table.stats[:skipped] - @spf_skipped).each { |why| log(:warn, nil, "SPF skipped #{why}") }
        @spf_skipped = table.stats[:skipped]
        table
      end

      # ---- log ----

      # Debug lines go to the logger only: kept in the event list they
      # would push out the events people look for.
      def log(level, iface, message)
        record(level, message, iface) unless level == :debug
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

      # ---- summary-LSAs (RFC 2328 12.4.3) ----

      # As an area border router, each attached area gets a summary-LSA
      # for every route it cannot see itself: type 3 for networks, type 4
      # for AS boundary routers. Without that role, our summaries go.
      def originate_summaries(table)
        abr = abr?
        @areas.each_value do |a|
          a.summaries = abr && a.active? ? summaries_for(a, table) : {}
        end
      end

      def summaries_for(area, table)
        specs = {}
        ids = {} # ls_id => [prefix, len] already used in this area (Appendix E)
        if (stub = area.stub)
          # 12.4.3.1: a default route stands in for the externals, and
          # with no-summaries for everything else too.
          ids[0] = [0, 0]
          specs[[3, 0, @router_id]] = { type: 3, ls_id: 0, body: [0, stub[:default_metric] || 1].pack('NN') }
          return specs if stub[:no_summaries]
        elsif (n = area.nssa) && n[:no_summaries]
          # A totally stubby NSSA: a type 3 default, nothing else (RFC 3101 2.7).
          metric = n.dig(:default_lsa, :metric) || 1
          return { [3, 0, @router_id] => { type: 3, ls_id: 0, body: [0, metric].pack('NN') } }
        end
        table.routes.values.sort_by { |r| [r.prefix_len, r.prefix] }.each do |r|
          next unless summarize?(r, area)
          next if area.stub? && r.prefix_len.zero? # our default is the one there
          ls_id = summary_ls_id(r, ids) or next
          specs[[3, ls_id, @router_id]] = { type: 3, ls_id: ls_id, body: [Addr.mask(r.prefix_len), r.cost].pack('NN') }
        end
        best_asbrs(table).each_value do |r|
          next unless area.external_capable? # no type 5 there, so no ASBRs to reach
          next unless summarize?(r, area) && r.prefix != @router_id
          specs[[4, r.prefix, @router_id]] = { type: 4, ls_id: r.prefix, body: [0, r.cost].pack('NN') }
        end
        specs
      end

      # 12.4.3: intra-area routes go into every other area; inter-area
      # routes (learned over the backbone) into the other areas but the
      # backbone, never out of the interfaces they arrive by. Externals are
      # not summarized, and nothing unreachable is.
      def summarize?(r, area)
        return false if r.area.nil? || r.area == area.id || r.cost >= Spf::LS_INFINITY
        case r.path_type
        when :intra then true
        when :inter
          return false if area.id.zero?
          names = area.interfaces.map(&:name)
          r.next_hops.none? { |h| names.include?(h.interface) }
        else false
        end
      end

      # The cheapest entry per ASBR, whatever area it is in.
      def best_asbrs(table)
        table.routers.values.select { |r| r.tag && r.tag[:asbr] }
             .group_by(&:prefix).transform_values { |rs| rs.min_by { |r| [r.cost, r.path_type == :intra ? 0 : 1] } }
      end

      # The network address, or with the host bits set when a shorter
      # prefix holds it already (RFC 2328 Appendix E).
      def summary_ls_id(r, ids)
        want = [r.prefix, r.prefix_len]
        [r.prefix, r.prefix | (~Addr.mask(r.prefix_len) & 0xffff_ffff)].each do |id|
          next if ids.key?(id) && ids[id] != want
          ids[id] = want
          return id
        end
        log(:warn, nil, "no link state id left for a summary of #{r.dest_s}")
        nil
      end

      # Floods our externals: they are AS-wide, so any area of ours that
      # carries externals will do. With none up yet, they go out when one is.
      def originate_externals
        return unless @running
        area = @areas.values.find { |a| a.active? && a.external_capable? } or return
        @externals.each_value { |spec| originate(area, spec) }
      end

      # [{ prefix:, prefix_len:, metric:, type:, tag:, forwarding: }] as
      # LSA specs of +type+ (5 or 7). +options+ for type 7 carries the P bit.
      def external_specs(type, routes, options)
        specs = {}
        ids = {}
        routes.sort_by { |r| [r[:prefix_len], r[:prefix]] }.each do |r|
          len = r[:prefix_len]
          prefix = r[:prefix] & Addr.mask(len)
          ls_id = summary_ls_id(Spf::Route.new(prefix: prefix, prefix_len: len), ids) or next
          e = r[:type] == 1 ? 0 : 0x8000_0000
          metric = [r[:metric].to_i, Spf::LS_INFINITY - 1].min
          body = [Addr.mask(len), e | metric, r[:forwarding].to_i, r[:tag].to_i].pack('NNNN')
          spec = { type: type, ls_id: ls_id, body: body }
          spec[:options] = r.fetch(:options, options) if type == 7
          specs[[type, ls_id, @router_id]] = spec
        end
        specs
      end

      # Type 7 LSAs for NSSA +area+. Our own routes go in with the P bit set
      # and one of our addresses in the area as forwarding address, so an
      # NSSA border router can translate them; an NSSA border router itself
      # originates the type 5 and sets no P bit (RFC 3101 2.3, 2.4). The
      # border router also sends the default, if configured (2.7).
      def nssa_specs(area)
        abr = abr?
        fwd = abr ? 0 : nssa_forwarding(area)
        p = !abr && !fwd.nil?
        routes = @exported.map { |r| r.merge(forwarding: p ? fwd : 0, options: p ? 0x08 : 0x00) }
        n = area.nssa
        if abr && (d = n[:default_lsa]) && !n[:no_summaries]
          routes << { prefix: 0, prefix_len: 0, metric: d[:metric], type: d[:type], tag: 0, forwarding: 0, options: 0x00 }
        end
        external_specs(7, routes, 0x00)
      end

      # An address of ours in the area, a passive (loopback) one first.
      def nssa_forwarding(area)
        up = area.interfaces.select(&:up?)
        (up.find(&:passive?) || up.first)&.address
      end

      # As the elected translator of an NSSA, the type 7 routes from it that
      # won in our table, P bit set and a forwarding address, go out again
      # as type 5 (RFC 3101 3.2). The translator is the NSSA border router
      # with the highest router id (3.1).
      def translations(table)
        return [] unless abr?
        @areas.values.select { |a| a.nssa? && a.active? && translator?(a, table) }.flat_map do |a|
          table.routes.values.filter_map do |r|
            next unless r.lsa_type == 7 && r.area == a.id && r.p_bit && r.forwarding
            { prefix: r.prefix, prefix_len: r.prefix_len, metric: r.lsa_metric, type: r.path_type == :ext1 ? 1 : 2,
              tag: r.tag.to_i, forwarding: r.forwarding }
          end
        end
      end

      def translator?(area, table)
        others = table.routers.values.select { |r| r.area == area.id && r.path_type == :intra && r.tag && r.tag[:abr] }
        others.none? { |r| r.prefix > @router_id }
      end

      def lsdb_changed(lsa, _old)
        return unless @running
        @spf.trigger(lsa.type_name, lsa.type == 1 ? Addr.to_s(lsa.advr) : "#{Addr.to_s(lsa.ls_id)} from #{Addr.to_s(lsa.advr)}")
      end

      def spf_areas
        @areas.values.map do |a|
          links = a.interfaces.select(&:up?).map do |i|
            Spf::Link.new(name: i.name, address: i.address, prefix_len: i.prefix_len,
                          neighbors: i.full_neighbors.to_h { |n| [n.router_id, n.address] })
          end
          Spf::Area.new(id: a.id, lsas: a.lsdb.live, interfaces: links, nssa: a.nssa?)
        end
      end

      def replace_routes(table, reasons, duration)
        diff = Spf.diff(@route_table.routes, table.routes)
        @route_table = table
        @spf_log << SpfRun.new(time: @loop.clock.wall, reasons: reasons, duration: duration,
                               routes: table.routes.size, diff: diff)
        @spf_log.shift(@spf_log.size - MAX_SPF_LOG) if @spf_log.size > MAX_SPF_LOG
        return if diff.empty?
        log(:info, nil, "routes #{diff} after SPF (#{reasons.first(3).join(', ')}#{reasons.size > 3 ? ', ...' : ''})")
        @route_listeners.each { |l| l.call(diff) }
      end

      # An area with no interfaces left: stop refreshing our LSAs in it and
      # forget it.
      def drop_area(area)
        # AS-wide LSAs are not the area's: they keep refreshing.
        @own.select { |sk, o| !sk[0].nil? && o[:area].equal?(area) }.each_key do |key|
          @own.delete(key)[:refresh]&.cancel
          @deferred.delete(key)&.cancel
        end
        @areas.delete(area.id)
        @spf.trigger(:area, area.id_s) if @running
      end

      # An LSA key made unique across areas: [area id or nil for AS scope, *key].
      def scope_key(area, key) = [AS_SCOPE.include?(key[0]) ? nil : area.id, *key]

      def install_own(area, lsa)
        db = lsdb_for(lsa.type, area)
        db.install(lsa)
        @stats[:lsa_originated] += 1
        sk = scope_key(area, lsa.key)
        o = (@own[sk] ||= { area: area, key: lsa.key })
        @last_origination[sk] = @loop.now
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
        @last_origination[scope_key(area, lsa.key)] = @loop.now if lsa.advr == @router_id
        log(:info, nil, "flushing #{lsa.id_string}")
        drop_old_retransmits(lsa, area)
        flood(lsa, area)
      end

      # RFC 2328 13.4: one of our own LSAs came back newer than ours.
      def self_originated(lsa, area)
        key = lsa.key
        sk = scope_key(area, key)
        if lsa.advr == @router_id && area.wants?(key) && !@own.dig(sk, :wrap)
          # Jump past the sequence number that came back, now rather than
          # after MinLSInterval.
          @own[sk] ||= { area: area, key: key }
          @deferred.delete(sk)&.cancel
          @last_origination.delete(sk)
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
            @spf.trigger(:maxage, e.lsa.id_string)
            flood(db.current(e), area)
          end
          next if exchanging?(key[0], area)
          next if scope_interfaces(key[0], area).any? { |i| i.neighbors.each_value.any? { |n| n.retransmitting?(key) } }
          db.delete(key)
          if (o = @own[scope_key(area, key)]) && o[:wrap]
            @own.delete(scope_key(area, key))
            spec = area.spec_for(key)
            originate(area, spec) if spec
          end
        end
      end
    end
  end
end
