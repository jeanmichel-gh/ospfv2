# frozen_string_literal: true

require_relative '../infra/event_loop'
require_relative 'addr'
require_relative 'lsa'
require_relative 'lsdb'
require_relative 'wire'
require_relative 'neighbor'
require_relative 'interface'
require_relative 'area'
require_relative 'virtual_link'
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
      # One protocol event. +kind+ says what happened (:neighbor, :spf, ...;
      # :log for plain messages) and +data+ carries its fields, so a program
      # need not parse +message+.
      Event = Struct.new(:time, :level, :interface, :message, :kind, :data) do
        def to_s = "#{time.strftime('%H:%M:%S')} #{interface ? "#{interface} " : ''}#{message}"
      end

      MAX_EVENTS = 2000
      MAX_SPF_LOG = 100

      # One SPF run, for show ospf log and show ip ospf statistics. +n+ its
      # number; +triggered_at+ the first trigger, +time+ when it started,
      # +duration+ the calculation, +fib_duration+ handing the route
      # changes to the kernel (nil when none changed); +delay+ the back-off
      # delay it waited (:initial, :short, :long, :now).
      SpfRun = Struct.new(:n, :time, :triggered_at, :delay, :reasons, :duration, :fib_duration, :fib_done_at, :routes, :diff,
                          keyword_init: true)
      AS_SCOPE = [5].freeze
      AREA_SCOPE = [1, 2, 3, 4, 7].freeze

      attr_reader :router_id, :loop, :areas, :interfaces, :as_lsdb, :random, :events, :stats,
                  :route_table, :spf, :spf_log, :externals, :virtual_links
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
        @lsa_runs = {}   # LSA key => [seq, SPF run it triggered]
        @route_runs = {} # route destination => SPF run that last changed it
        @arrival = nil   # where the LSA being installed came from, for its SPF trigger
        @externals = {} # key => spec, the AS-external-LSAs we originate
        @virtual_links = {} # neighbor router id => VirtualLink
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
        @event_listeners = []
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

      # A virtual link to area border router +neighbor+ across +transit_area+
      # (RFC 2328 15). It comes up once the transit area's SPF reaches the
      # other end. opts: hello_interval, dead_interval, rxmt_interval,
      # transmit_delay, auth.
      def add_virtual_link(neighbor:, transit_area:, **opts)
        transit = Addr.to_i(transit_area.is_a?(Integer) ? transit_area : transit_area.to_s)
        rid = Addr.to_i(neighbor)
        raise ArgumentError, 'a virtual link cannot cross the backbone' if transit.zero?
        raise ArgumentError, "virtual link to #{Addr.to_s(rid)} already exists" if @virtual_links.key?(rid)
        vl = VirtualLink.new(self, neighbor_id: rid, transit_area_id: transit, area: area(0), **opts)
        area(0).interfaces << vl
        @interfaces[vl.name] = vl
        @virtual_links[rid] = vl
        update_virtual_links(@route_table) if @running
        vl
      end

      def remove_virtual_link(neighbor)
        vl = @virtual_links.delete(Addr.to_i(neighbor)) or return nil
        remove_interface(vl.name)
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
        @spf.trigger(:interface, name, source: { source: 'interface', interface: name, to: 'removed' }) if @running
        log(:info, iface, "interface #{name} removed", kind: :interface, state: 'removed')
        iface
      end

      def start
        return self if @running
        @running = true
        log(:info, nil, "router #{router_id_s} starting", kind: :router, state: 'starting', router_id: router_id_s)
        # Virtual links come up when SPF reaches their other end.
        @interfaces.each_value { |i| i.up unless i.virtual? }
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
        replace_routes(Spf::Table.empty, [SpfScheduler::Reason.new(:stop, nil, nil, nil, @loop.clock.wall)], 0.0) unless @route_table.routes.empty?
        log(:info, nil, "router #{router_id_s} stopped", kind: :router, state: 'stopped', router_id: router_id_s)
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

      # Databases summarized in DDs; AS-external LSAs never go over
      # virtual links (RFC 2328 10.3).
      def lsdbs_for(area, virtual: false)
        area.external_capable? && !virtual ? [area.lsdb, @as_lsdb] : [area.lsdb]
      end

      def scope_interfaces(type, area)
        return area.interfaces unless AS_SCOPE.include?(type)
        @interfaces.values.select { |i| i.area.external_capable? && !i.virtual? }
      end

      # ---- hooks from interfaces and neighbors ----

      def neighbor_changed(nbr, old, new)
        nbr.iface.forget(nbr) if new == :down
        if old == :full || new == :full
          nbr.iface.area.schedule_origination
          # The V bit in the transit area's router-LSA follows the link.
          @areas[nbr.iface.transit_area_id]&.schedule_origination if nbr.iface.virtual?
          @spf.trigger(:neighbor, Addr.to_s(nbr.router_id),
                       source: { source: 'neighbor state', router_id: Addr.to_s(nbr.router_id), interface: nbr.iface.name,
                                 from: old.to_s, to: new.to_s })
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
        @spf.trigger(:interface, iface.name, source: { source: 'interface', interface: iface.name, from: old.to_s, to: new.to_s })
      end

      # Attached to the backbone and another area: an area border router
      # (RFC 3509; a router in two areas but not the backbone is not one,
      # as on most implementations).
      def abr? = @areas.values.count(&:active?) > 1 && @areas[0]&.active? == true

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
          db = nil if iface.virtual? && AS_SCOPE.include?(lsa.type)
          unless db
            why = case lsa.type
                  when *AS_SCOPE then iface.virtual? ? 'AS-external LSA over a virtual link' : 'AS-external LSA in a stub area or NSSA'
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
            arriving(source: 'neighbor', router_id: Addr.to_s(nbr.router_id), address: Addr.to_s(nbr.address),
                     interface: iface.name) { db.install(lsa) }
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
        db = own_db(spec[:type], area)
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
        db = own_db(key[0], area)
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
        started = @loop.clock.wall
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        table = Spf.run(router_id: @router_id, areas: spf_areas, externals: @as_lsdb.live, max_paths: @max_paths)
        @stats[:spf_runs] += 1
        prev = @route_table
        replace_routes(table, reasons, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, started: started)
        update_virtual_links(table)
        # Summaries and externals depend on the table and on how we sit in
        # our areas. When neither changed, there is nothing to redo: with
        # many routes that saves seconds per run.
        sig = origination_signature(table)
        if sig != @origination_sig || !Spf.diff(prev.routes, table.routes).empty?
          @origination_sig = sig
          originate_summaries(table)
          refresh_externals(table)
        end
        # Warn once per bad LSA, not on every run.
        (table.stats[:skipped] - @spf_skipped).each { |why| log(:warn, nil, "SPF skipped #{why}", kind: :spf_skipped, why: why.to_s) }
        @spf_skipped = table.stats[:skipped]
        table
      end

      def origination_signature(table)
        routers = table.routers.transform_values { |r| [r.path_type, r.cost, r.tag, r.next_hops.map(&:sort_key).sort] }
        areas = @areas.values.map { |a| [a.id, a.active?, a.interfaces.select(&:up?).map { |i| [i.name, i.address] }] }
        [abr?, areas, @area_options, routers]
      end

      # ---- virtual links (RFC 2328 15) ----

      # After each SPF: a virtual link is up while the transit area reaches
      # the other end (an area border router, 16.1 step 4). Its cost is the
      # path's; its addresses are ours on the way out and the other end's
      # in the transit area.
      def update_virtual_links(table)
        @virtual_links.each_value do |vl|
          entry = table.routers[[vl.neighbor_id, vl.transit_area_id]]
          area = @areas[vl.transit_area_id]
          hop = entry&.next_hops&.first
          iface = hop && @interfaces[hop.interface]
          remote = entry && area && (entry.address || virtual_remote(area, vl.neighbor_id, hop))
          if entry && entry.path_type == :intra && iface && remote && area.active? && !area.stub? && !area.nssa?
            vl.reach(cost: entry.cost, local: iface.address, remote: remote, via: iface.name)
          else
            vl.unreach
          end
        end
      end

      # The other end's address: the next hop when it is our neighbor,
      # else an interface address from its router-LSA in the transit area.
      def virtual_remote(area, rid, hop)
        if hop.gateway
          nbr = @interfaces[hop.interface]&.neighbors&.each_value&.find { |n| n.address == hop.gateway }
          return hop.gateway if nbr&.router_id == rid
        end
        lsa = area.lsdb[[1, rid, rid]] or return nil
        link = lsa.router_links.find { |l| [1, 2].include?(l.type) } or return nil
        link.data
      rescue Lsa::Error
        nil
      end

      # A backbone packet that came in on +phys+, a non-backbone interface:
      # for the virtual link to its sender through that area, if any.
      def virtual_receive(bytes, from, phys)
        hdr = Wire.peek(bytes)
        vl = @virtual_links.each_value.find { |v| v.transit_area_id == phys.area.id && v.neighbor_id == hdr.router_id }
        return phys.drop(:packet, "backbone packet from #{from}, no virtual link to #{Addr.to_s(hdr.router_id)}") unless vl
        vl.receive(bytes, from)
      end

      # Sends a virtual link's packet out of the interface its path takes.
      def virtual_send(vl, bytes, dest)
        iface = vl.via && @interfaces[vl.via]
        iface&.transport&.send_packet(bytes, dest)
      end

      # ---- log ----

      # Debug lines go to the logger only: kept in the event list they
      # would push out the events people look for.
      #
      #   log(:info, iface, "neighbor ...", kind: :neighbor, router_id: '2.2.2.2', ...)
      def log(level, iface, message, kind: :log, **data)
        record(level, message, iface, kind: kind, **data) unless level == :debug
        @logger&.call(level, iface ? "#{iface.name} #{message}" : message)
      end

      # Adds an event to the list without passing it to the logger, and
      # tells the event listeners.
      def record(level, message, iface = nil, kind: :log, **data)
        ev = Event.new(@loop.clock.wall, level, iface&.name, message, kind, data)
        @events << ev
        @events.shift(@events.size - MAX_EVENTS) if @events.size > MAX_EVENTS
        notify_event(ev)
        ev
      end

      # Calls the block with each Event as it happens, on the loop thread.
      # Gets every recorded event, plus some that are not kept in the list
      # because they have their own (an SPF run is in the SPF log).
      def on_event(&block)
        @event_listeners << block
        block
      end

      def remove_event_listener(block)
        @event_listeners.delete(block)
      end

      # Tells the listeners without keeping the event in the list.
      def publish(level, message, iface = nil, kind:, **data)
        notify_event(Event.new(@loop.clock.wall, level, iface&.name, message, kind, data))
      end

      def notify_event(ev)
        @event_listeners.each do |l|
          l.call(ev)
        rescue StandardError => e
          @logger&.call(:error, "event listener: #{e.class}: #{e.message}")
        end
      end

      def trace(dir, iface, pkt, peer)
        @tracer&.call(dir, iface.name, pkt, peer)
      end

      # Every timer of this router, with what it belongs to:
      # [{ kind:, ... }, name, timer]. Kinds: router, interface, neighbor,
      # lsa (its refresh, or an origination held by MinLSInterval), spf.
      def timers
        out = []
        out << [{ kind: 'router' }, :maxage_sweep, @sweep] if @sweep
        @interfaces.each_value do |i|
          i.timers.each { |n, t| out << [{ kind: 'interface', interface: i.name }, n, t] }
          i.neighbors.each_value do |nb|
            who = { kind: 'neighbor', interface: i.name, router_id: Addr.to_s(nb.router_id), address: Addr.to_s(nb.address) }
            nb.timers.each { |n, t| out << [who, n, t] }
          end
        end
        @own.each { |sk, o| out << [lsa_owner(sk), :ls_refresh, o[:refresh]] if o[:refresh] }
        @deferred.each { |sk, t| out << [lsa_owner(sk), :min_ls_interval, t] }
        @spf.timers.each { |n, t| out << [{ kind: 'spf' }, n, t] }
        out
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
        return false unless %i[intra inter].include?(r.path_type)
        return false if r.path_type == :inter && area.id.zero?
        # Never back into the area its traffic goes through (12.4.3): an
        # inter-area route, or a backbone route over a virtual link.
        names = area.interfaces.map(&:name)
        r.next_hops.none? { |h| names.include?(h.interface) }
      end

      # The cheapest entry per ASBR, whatever area it is in. An NSSA's ASBRs
      # are never summarized: their routes leave it as translated type 5s
      # (RFC 3101 2.2).
      def best_asbrs(table)
        table.routers.values.select { |r| r.tag && r.tag[:asbr] && !@areas[r.area]&.nssa? }
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
        @no_ls_id ||= {}
        log(:warn, nil, "no link state id left for #{r.dest_s} (RFC 2328 Appendix E), not advertised") unless @no_ls_id[want]
        @no_ls_id[want] = true
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

      TRANSLATOR_STABILITY = 40 # seconds a translator keeps going after losing (RFC 3101 3.1)

      # Candidates: NSSA border routers reachable inside the NSSA and over
      # the backbone. One with the Nt bit always translates; otherwise the
      # highest router id does. A translator that loses keeps translating
      # for TRANSLATOR_STABILITY seconds, so a flap does not drop routes.
      def translator?(area, table)
        @translating ||= {}
        backbone = table.routers.keys.select { |_, a| a.zero? }.map(&:first)
        cands = table.routers.values.select do |r|
          r.area == area.id && r.path_type == :intra && r.tag && r.tag[:abr] && backbone.include?(r.prefix)
        end
        elected = @areas[0]&.active? && cands.none? { |r| r.tag[:nt] || r.prefix > @router_id }
        if elected
          @translating[area.id] = :yes
        elsif @translating[area.id] == :yes
          @translating[area.id] = @loop.now
          log(:info, nil, "area #{area.id_s}: no longer the NSSA translator, stopping in #{TRANSLATOR_STABILITY} s")
          @loop.after(TRANSLATOR_STABILITY, :nssa_translator) { refresh_externals }
        elsif @translating[area.id].is_a?(Numeric) && @loop.now - @translating[area.id] >= TRANSLATOR_STABILITY
          @translating.delete(area.id)
        end
        @translating.key?(area.id)
      end

      def lsdb_changed(lsa, _old)
        return unless @running
        # SPF never uses our own summaries and externals: no run for them.
        return if lsa.advr == @router_id && [3, 4, 5, 7].include?(lsa.type)
        @spf.trigger(lsa.type_name, lsa.type == 1 ? Addr.to_s(lsa.advr) : "#{Addr.to_s(lsa.ls_id)} from #{Addr.to_s(lsa.advr)}",
                     lsa: lsa.instance_fields.merge(type: lsa.type, age: lsa.age), source: @arrival || { source: 'unknown' })
      end

      def spf_areas
        @areas.values.map do |a|
          links = a.interfaces.select(&:up?).sort_by { |i| i.virtual? ? 1 : 0 }.map do |i|
            Spf::Link.new(name: i.name, address: i.address, prefix_len: i.prefix_len,
                          neighbors: i.full_neighbors.to_h { |n| [n.router_id, n.address] },
                          virtual: i.virtual? ? [i.neighbor_id, i.transit_area_id] : nil)
          end
          Spf::Area.new(id: a.id, lsas: a.lsdb.live, interfaces: links, nssa: a.nssa?,
                        no_summaries: a.nssa&.[](:no_summaries) == true)
        end
      end

      # The new table in, the kernel told (route listeners), the run kept
      # in the log and announced. LSAs that triggered it and routes it
      # changed remember its number.
      def replace_routes(table, reasons, duration, started: @loop.clock.wall)
        diff = Spf.diff(@route_table.routes, table.routes)
        @route_table = table
        n = @spf.runs
        fib = nil
        unless diff.empty?
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @route_listeners.each { |l| l.call(diff) }
          fib = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        end
        run = SpfRun.new(n: n, time: started, triggered_at: reasons.filter_map(&:at).min, delay: @spf.last_delay,
                         reasons: reasons, duration: duration, fib_duration: fib, fib_done_at: fib && @loop.clock.wall,
                         routes: table.routes.size, diff: diff)
        @spf_log << run
        @spf_log.shift(@spf_log.size - MAX_SPF_LOG) if @spf_log.size > MAX_SPF_LOG
        remember_run(run)
        why = "#{reasons.first(3).join(', ')}#{reasons.size > 3 ? ', ...' : ''}"
        publish(:info, "SPF #{(duration * 1000).round(1)} ms, #{table.routes.size} routes, #{diff} (#{why})",
                kind: :spf, **spf_run_fields(run))
        return if diff.empty?
        log(:info, nil, "routes #{diff} after SPF (#{why})", kind: :routes, run: n,
                                                             added: diff.added.size, changed: diff.changed.size,
                                                             removed: diff.removed.size)
      end

      # A run as plain data: for events and show.spf.
      def spf_run_fields(run)
        wait = run.triggered_at && ((run.time - run.triggered_at) * 1000).round(3)
        all = run.diff.added.size + run.diff.changed.size + run.diff.removed.size
        { run: run.n, triggered_at: run.triggered_at&.utc&.iso8601(3), started_at: run.time.utc.iso8601(3),
          wait_ms: wait, delay: run.delay&.to_s, duration_ms: (run.duration * 1000).round(3),
          fib_ms: run.fib_duration && (run.fib_duration * 1000).round(3), fib_done_at: run.fib_done_at&.utc&.iso8601(3),
          routes: run.routes, added: run.diff.added.size, changed: run.diff.changed.size, removed: run.diff.removed.size,
          reasons: run.reasons.map do |r|
            { kind: r.kind.to_s, detail: r.detail&.to_s, lsa: r.lsa, source: r.source, at: r.at&.utc&.iso8601(3) }.compact
          end,
          prefixes: spf_prefixes(run.diff), more: [all - SPF_EVENT_PREFIXES, 0].max }
      end

      # The SPF run an LSA instance triggered, if one did: [type, ls_id, advr] and its seq.
      def spf_run_of_lsa(key, seq)
        seen, n = @lsa_runs[key]
        seen == seq ? n : nil
      end

      # The SPF run that last changed the route to +dest+ ("10.0.0.0/24").
      def spf_run_of_route(dest) = @route_runs[dest]
      public :spf_run_fields, :spf_run_of_lsa, :spf_run_of_route

      SPF_EVENT_PREFIXES = 50 # prefixes listed per SPF event; the counts cover all

      def remember_run(run)
        run.reasons.each do |r|
          next unless r.lsa
          @lsa_runs[[r.lsa[:type], Addr.to_i(r.lsa[:ls_id]), Addr.to_i(r.lsa[:advr])]] = [r.lsa[:seq], run.n]
        end
        run.diff.added.each { |x| @route_runs[x.dest_s] = run.n }
        run.diff.changed.each { |_, x| @route_runs[x.dest_s] = run.n }
        run.diff.removed.each { |x| @route_runs.delete(x.dest_s) }
      end

      # Installs into the LSDB with +source+ noted, so the SPF trigger the
      # change sets off says where the LSA came from.
      def arriving(**source)
        @arrival = source
        yield
      ensure
        @arrival = nil
      end

      def spf_prefixes(diff)
        list = diff.added.map { |r| ['+', r.dest_s] } + diff.changed.map { |_, r| ['~', r.dest_s] } +
               diff.removed.map { |r| ['-', r.dest_s] }
        list.first(SPF_EVENT_PREFIXES).map { |m, p| "#{m}#{p}" }
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
      def lsa_owner(sk)
        area, type, ls_id, advr = sk
        { kind: 'lsa', area: area && Addr.to_s(area), type: type, ls_id: Addr.to_s(ls_id), advr: Addr.to_s(advr) }
      end

      def scope_key(area, key) = [AS_SCOPE.include?(key[0]) ? nil : area.id, *key]

      # Where our own LSA of +type+ lives: the AS database for externals,
      # whatever the area (it may have become a stub or NSSA since), else
      # the area's.
      def own_db(type, area) = AS_SCOPE.include?(type) ? @as_lsdb : area.lsdb

      def install_own(area, lsa)
        db = own_db(lsa.type, area)
        arriving(source: 'self') { db.install(lsa) }
        @stats[:lsa_originated] += 1
        sk = scope_key(area, lsa.key)
        o = (@own[sk] ||= { area: area, key: lsa.key })
        @last_origination[sk] = @loop.now
        o.delete(:wrap)
        # Jittered, so LSAs originated together do not all refresh together.
        o[:refresh] ||= @loop.every(OSPFv2::LSRefreshTime, :ls_refresh, start: false, jitter: 0.1) do
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
        arriving(source: lsa.advr == @router_id ? 'self' : 'flush') { own_db(lsa.type, area).install(lsa) }
        # A flush is a new instance too: the next origination waits
        # MinLSInterval, or routers two hops away drop it (13 step 5a).
        @last_origination[scope_key(area, lsa.key)] = @loop.now if lsa.advr == @router_id
        log(:info, nil, "flushing #{lsa.id_string}", kind: :lsa, change: 'flush', **lsa.instance_fields)
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
            log(:info, nil, "#{e.lsa.id_string} reached MaxAge", kind: :lsa, change: 'maxage', **e.lsa.instance_fields)
            @spf.trigger(:maxage, e.lsa.id_string, lsa: e.lsa.instance_fields.merge(type: e.lsa.type, age: e.lsa.age),
                                                   source: { source: 'maxage' })
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
