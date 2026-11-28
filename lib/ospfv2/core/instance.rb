# frozen_string_literal: true

require 'time' # Time#iso8601 for SPF runs, without the daemon
require_relative '../infra/event_loop'
require_relative 'addr'
require_relative 'lsa'
require_relative 'validation'
require_relative 'router_information'
require_relative 'extended'
require_relative 'sr_labels'
require_relative 'lsdb'
require_relative 'wire'
require_relative 'neighbor'
require_relative 'interface'
require_relative 'area'
require_relative 'virtual_link'
require_relative 'spf'
require_relative 'lsdb_topology'
require_relative 'spf_scheduler'
require_relative 'bfd'

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
      # Types 9 to 11 are opaque (RFC 5250 section 3): 9 link-local, 10
      # area-local, 11 AS-wide. They are held only while opaque is on.
      AS_SCOPE = [5, 11].freeze
      AREA_SCOPE = [1, 2, 3, 4, 7, 10].freeze
      OPAQUE = [9, 10, 11].freeze
      # The O bit, set in DD options only (RFC 5250 section 3.1).
      O_BIT = 0x40
      # Our Router Information LSA's link state ID: opaque type 4, ID 0
      # (RFC 7770 section 2.1).
      RI_ID = RouterInformation::OPAQUE_TYPE << 24

      attr_reader :router_id, :receive_policy, :loop, :areas, :interfaces, :as_lsdb, :random, :events, :stats,
                  :route_table, :spf, :spf_log, :externals, :virtual_links
      # area id => { stub: { default_metric:, no_summaries: } }
      attr_accessor :area_options
      # The Core::Bfd that asks for BFD sessions, if any (it sets itself).
      attr_accessor :bfd

      # router_id: dotted quad or Integer
      # loop:      the EventLoop that owns this router
      # logger:    optional ->(level, message) for every event
      # tracer:    optional ->(direction, interface, packet, peer) per packet
      # spf:       RFC 8405 timers in seconds, see SpfScheduler::DEFAULTS
      # max_paths: equal-cost next hops kept per route
      # +receive_policy+: :rfc, :strict or :lenient (Validation). Every
      # rule ospfd acts on today takes the same action under each, so it
      # changes nothing yet; SR's rules differ (docs/design/sr-ospf.md).
      def initialize(router_id:, loop:, random: Random.new, logger: nil, tracer: nil, spf: {}, max_paths: 16,
                     receive_policy: :rfc)
        @router_id = Addr.to_i(router_id)
        @receive_policy = Validation.policy(receive_policy)
        @opaque = false
        @opaque_specs = {} # [area id or nil, key] => { type:, ls_id:, body:, options: }
        @sr_capabilities = nil
        @sr = nil
        @adj_labels = {}   # [interface name, neighbor router id] => label from the SRLB
        @link_oids = {}    # [area id, link key] => opaque ID of its extended link LSA
        @prefix_oids = {}  # [area id, "p/len"] => opaque ID of an inter-area extended prefix LSA
        @sr_labels = nil
        @sr_found = []     # findings already announced (sr_finding)
        @labels_pending = false
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
        @areas[id] ||= Area.new(self, id).tap { |a| a.lsdb.on_change = ->(lsa, old) { lsdb_changed(lsa, old, a) } }
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

      # ---- opaque LSAs (RFC 5250) ----

      def opaque? = @opaque

      # Turns opaque on or off. A change takes every adjacency down, so
      # each forms again with the new DD options; off, the opaque LSAs
      # held are dropped and ours flushed first.
      def opaque=(on)
        on = on ? true : false
        return if on == @opaque
        unless on
          self.opaque_lsas = []
          @areas.each_value { |a| flush_own(a, [10, RI_ID, @router_id]) }
          @areas.each_value(&:flush_sr)
        end
        @opaque = on
        @areas.each_value(&:schedule_origination) if on && @running
        unless on
          ([@as_lsdb] + @areas.values.map(&:lsdb) + @interfaces.values.map(&:link_lsdb)).each do |db|
            db.map(&:key).select { OPAQUE.include?(_1[0]) }.each { db.delete(_1) }
          end
        end
        neighbors.each { |n| n.kill(on ? 'opaque on' : 'opaque off') }
      end

      # Sets the opaque LSAs we originate, as externals= does externals:
      #   [{ type: 10, area: '0.0.0.0', opaque_type: 4, opaque_id: 0, body: }]
      #   [{ type: 11, opaque_type: 4, opaque_id: 0, body: }]
      # New and changed ones are originated, the rest flushed. Type 9 is
      # not originated yet: nothing here needs one.
      def opaque_lsas=(list)
        raise ArgumentError, 'opaque is off' unless @opaque || list.empty?
        want = list.to_h do |o|
          type = o.fetch(:type)
          raise ArgumentError, "type #{type}: ospfd originates opaque types 10 and 11" unless [10, 11].include?(type)
          ot = o.fetch(:opaque_type)
          oid = o.fetch(:opaque_id)
          raise ArgumentError, "opaque type #{ot}: 0 to 255" unless ot.between?(0, 255)
          raise ArgumentError, "opaque ID #{oid}: 0 to 16777215" unless oid.between?(0, 0xff_ffff)
          ls_id = (ot << 24) | oid
          raise ArgumentError, 'the Router Information LSA 4.0.0.0 is ospfd\'s own' if type == 10 && ls_id == RI_ID
          raise ArgumentError, "opaque type #{ot}: ospfd's own with SR" if [7, 8].include?(ot)
          aid = type == 10 ? Addr.to_i(o.fetch(:area)) : nil
          [[aid, [type, ls_id, @router_id]], { type: type, ls_id: ls_id, body: o.fetch(:body).b }]
        end
        old = @opaque_specs
        @opaque_specs = want
        return unless @running
        (old.keys - want.keys).each do |aid, key|
          a = opaque_area(aid)
          flush_own(a, key) if a
        end
        want.each_key { |aid, _| opaque_area(aid)&.schedule_origination }
      end

      # SR-MPLS (RFC 8665), or nil for off:
      #   { srgb: [first, size], srlb: [first, size], index: 1 or nil, no_adj_sid: [interface names] }
      # It needs opaque on. It sets our RI LSA's SR TLVs; each area then
      # originates our Node-SID and Adj-SIDs (Area#sr_specs).
      def segment_routing = @sr

      # The Adj-SID labels given out: [interface name, router id] => label.
      attr_reader :adj_labels

      # The label table of the last calculation (SrLabels), or nil without SR.
      attr_reader :sr_labels

      # Builds the label table, announces new findings (an sr_finding
      # event each, once), and has an ABR re-originate its inter-area SIDs
      # when they changed. After each SPF run, and on a change to an opaque
      # LSA or an adjacency, which run no SPF.
      # +notify+: tell the route listeners (the FIB) when the label table
      # changed; an SPF run that changed routes tells them itself.
      def compute_labels(notify: true)
        @labels_pending = false
        old = @sr_labels&.sids
        before = @sr_labels && [@sr_labels.entries, @sr_labels.out_labels]
        @sr_labels = @sr && @opaque ? SrLabels.new(self).build : nil
        after = @sr_labels && [@sr_labels.entries, @sr_labels.out_labels]
        @route_listeners.each { |l| l.call(Spf::Diff.new([], [], [])) } if notify && before != after
        found = @sr_labels&.findings || []
        (found - @sr_found).each { announce_sr_finding(_1) }
        @sr_found = found
        @areas.each_value(&:schedule_origination) if abr? && old != @sr_labels&.sids
      end

      def schedule_labels
        return if @labels_pending || !@running
        @labels_pending = true
        @loop.post { compute_labels if @labels_pending }
      end

      # docs/design/sr-ospf.md, "Answers for routescope", answer 8.
      def announce_sr_finding(f)
        rule = Validation.rule(f[:name])
        rfc = rule.clause[/\ARFC (\d+) section ([\d.]+)/] && "RFC #{$1} #{$2}"
        action = %i[ignore_sid ignore_range ignore_router ignore_lsa ignore_tlv drop_lsa use_first].include?(rule.actions.fetch(@receive_policy)) ? 'ignored' : 'no_label'
        lsa = f[:lsa] && { type: f[:lsa][:type], ls_id: f[:lsa][:ls_id], advr: f[:lsa][:advr] }
        log(:warn, nil, "SR: #{f[:subject]}: #{f[:detail]} (#{rule.clause})", kind: :sr_finding,
            finding: f[:name].to_s, rfc: rfc, action: action, area: f[:area], router_id: f[:lsa]&.dig(:advr) || f[:subject],
            lsa: lsa)
      end

      # The inter-area SIDs an ABR gives +area+ (RFC 8665 section 7.2): for
      # each type 3 of ours there, the SID of its route, from another area.
      # NP set and E clear, unless the prefix is ours (directly attached),
      # when our own flags go. { "p/len" => [index, flags] }
      def inter_area_sids(area)
        return {} unless @sr_labels && abr?
        area.summaries.each_value.filter_map do |spec|
          dest = spec[:dest] or next
          s = @sr_labels.sids[dest] or next
          r = @route_table.routes.values.find { _1.dest_s == dest }
          next unless r && r.area && r.area != area.id
          flags = Addr.to_i(s[:advr]) == @router_id ? s[:flags] : (s[:flags] | SrLabels::NP) & ~SrLabels::E
          [dest, [s[:index], flags]]
        end.to_h
      end

      # The opaque ID of an inter-area extended prefix LSA: 2 and up (1 is
      # the Node-SID's), kept while the prefix is summarized.
      def prefix_oid(area, dest)
        @prefix_oids[[area.id, dest]] ||= begin
          used = @prefix_oids.select { |(a, _), _| a == area.id }.values
          (2..0xff_ffff).find { !used.include?(_1) }
        end
      end

      def release_prefix_oids(area, live)
        @prefix_oids.delete_if { |(a, d), _| a == area.id && !live.include?(d) }
      end

      def segment_routing=(sr)
        @sr = sr&.dup&.freeze
        @adj_labels.clear unless @sr && @adj_labels.values.all? { in_block?(_1, @sr[:srlb]) }
        self.sr_capabilities = sr && { algorithms: [0], srgb: [sr[:srgb]], srlb: [sr[:srlb]] }
      end

      def in_block?(label, (first, size)) = label >= first && label < first + size

      # The Adj-SID label for +nbr+ on +iface+, from the SRLB, kept while
      # the adjacency lives (RFC 8665 section 6.1, P clear). nil when the
      # SRLB is used up.
      def adj_label(iface, nbr)
        key = [iface.name, nbr.router_id]
        @adj_labels[key] ||= begin
          first, size = @sr[:srlb]
          used = @adj_labels.values
          (first...(first + size)).find { !used.include?(_1) }
        end
      end

      # Lets go of the Adj-SID labels whose adjacencies are gone: +live+ is
      # the [interface name, router id] keys still in use in +area+.
      def release_adj_labels(area, live)
        names = area.interfaces.map(&:name)
        @adj_labels.delete_if { |k, _| names.include?(k[0]) && !live.include?(k) }
      end

      # The opaque ID of +area+'s extended link LSA for +key+, kept while
      # the link exists: the lowest one free. +live+ lets go of the rest.
      def link_oid(area, key)
        @link_oids[[area.id, key]] ||= begin
          used = @link_oids.select { |(a, _), _| a == area.id }.values
          (1..0xff_ffff).find { !used.include?(_1) }
        end
      end

      def release_link_oids(area, live)
        @link_oids.delete_if { |(a, k), _| a == area.id && !live.include?(k) }
      end

      # SR's TLVs in our RI LSA, or nil for none (step 4 sets them from
      # the configuration):
      #   { algorithms: [0], srgb: [[16000, 8000]], srlb: [[15000, 1000]] }
      attr_reader :sr_capabilities

      def sr_capabilities=(sr)
        @sr_capabilities = sr&.slice(:algorithms, :srgb, :srlb)
        @areas.each_value(&:schedule_origination) if @running
      end

      # Our RI LSA in each area while opaque is on (RFC 7770): the
      # capabilities TLV, then SR's TLVs when set.
      def ri_spec
        return nil unless @opaque
        { type: 10, ls_id: RI_ID, body: RouterInformation.build(**(@sr_capabilities || {})).encode }
      end

      # Each router's Router Information in +area+, by router ID (RFC
      # 7770; RFC 8665 section 3), under the receive policy:
      #   { router_id:, capabilities:, algorithms:, srgb: [[first, size]], srlb:, findings: [] }
      # Of several RI LSAs from one router, the lowest opaque ID with an
      # SR-Algorithm TLV gives SR's values (8665 section 3.1). algorithms
      # nil: not SR capable. A range that a finding ignores is left out.
      def router_information(area)
        area = @areas[Addr.to_i(area)] unless area.is_a?(Area)
        return {} unless area
        ris = area.lsdb.live.select { _1.type == 10 && (_1.ls_id >> 24) == RouterInformation::OPAQUE_TYPE }
        ris.sort_by { [_1.advr, _1.ls_id & 0xff_ffff] }.group_by(&:advr).to_h do |advr, list|
          rid = Addr.to_s(advr)
          found = list.flat_map { |l| Validation.opaque(RouterInformation::OPAQUE_TYPE, l.body, rid).map { [_1, l] } }
          findings = found.map(&:first)
          bodies = list.filter_map do |l|
            RouterInformation::Body.new(l.body)
          rescue Tlv::Error
            nil
          end
          row = { router_id: rid, capabilities: bodies.first&.capabilities, algorithms: nil, srgb: [], srlb: [],
                  findings: found.map { |f, l| f.to_hash.merge(lsa: l.instance_fields.slice(:ls_id, :advr).merge(type: l.type)) } }
          sr = bodies.find(&:algorithms)
          if sr && findings.none? { Validation.action(_1, @receive_policy) == :ignore_router }
            usable = ->(k) { sr.ranges(k).select { _1.size.positive? && _1.sid_labels == 1 }.map { |r| [r.first, r.size] } }
            row.merge!(algorithms: sr.algorithms, srgb: usable.(RouterInformation::SidLabelRange),
                       srlb: usable.(RouterInformation::Srlb))
          end
          [rid, row]
        end
      end

      # Each router's extended prefixes in +area+ (RFC 7684 section 2):
      # its type 10s there, and the type 11s.
      #   { router id => { prefixes: { "p/len" => { route_type:, flags:, opaque_id:, sids: [] } }, findings: [] } }
      # A prefix in several LSAs of one router takes the lowest opaque ID;
      # twice in one LSA, the first (2.1). A SID a finding ignores is left
      # out (RFC 8665 section 5).
      def extended_prefixes(area)
        read_extended(area, ExtendedPrefix) do |body, out, oid|
          body.prefixes.each do |t|
            next if out.key?(t.prefix_s) && out[t.prefix_s][:opaque_id] <= oid
            sids = t.sids.select { |s| s.flags.anybits?(ExtendedPrefix::PrefixSid::V) == s.flags.anybits?(ExtendedPrefix::PrefixSid::L) }
            # RFC 8665 section 5: several for one MT-ID and algorithm, all ignored.
            sids = sids.group_by { [_1.mt_id, _1.algorithm] }.values.select { _1.size == 1 }.flatten
            out[t.prefix_s] = { route_type: t.route_type, flags: t.flags, opaque_id: oid,
                                sids: sids.map { _1.to_hash.except(:type) } }
          end
        end.transform_values { |r| { prefixes: r[:items], findings: r[:findings] } }
      end

      # Each router's extended links in +area+ (RFC 7684 section 3), by
      # [link type, link ID, link data]; the lowest opaque ID for a link
      # in several LSAs, the first Extended Link TLV of one (3.1).
      #   { router id => { links: [{ link_type:, link_id:, link_data:, opaque_id:, adj_sids: [], lan_adj_sids: [] }], findings: [] } }
      def extended_links(area)
        # RFC 8665 sections 6.1 and 5: an Adj-SID with V and L unequal is ignored.
        valid = lambda do |sids|
          sids.select { |s| s.flags.anybits?(ExtendedLink::AdjSid::V) == s.flags.anybits?(ExtendedLink::AdjSid::L) }
              .map { _1.to_hash.except(:type) }
        end
        read_extended(area, ExtendedLink) do |body, out, oid|
          t = body.links.first or next
          next if out.key?(t.key) && out[t.key][:opaque_id] <= oid
          out[t.key] = { link_type: t.link_type, link_id: Addr.to_s(t.link_id), link_data: Addr.to_s(t.link_data),
                         opaque_id: oid, adj_sids: valid.(t.adj_sids), lan_adj_sids: valid.(t.lan_adj_sids) }
        end.transform_values { |r| { links: r[:items].values, findings: r[:findings] } }
      end

      # The opaque LSAs of +kind+'s opaque type in +area+ (and the AS's
      # type 11s), each router's in opaque ID order, decoded; the block
      # fills that router's items from each body. An LSA a finding
      # ignores under the policy is left out.
      def read_extended(area, kind)
        area = @areas[Addr.to_i(area)] unless area.is_a?(Area)
        return {} unless area
        lsas = (area.lsdb.live.select { _1.type == 10 } + @as_lsdb.live.select { _1.type == 11 })
               .select { (_1.ls_id >> 24) == kind::OPAQUE_TYPE }
        lsas.sort_by { [_1.advr, _1.ls_id & 0xff_ffff, _1.type] }.group_by(&:advr).to_h do |advr, list|
          rid = Addr.to_s(advr)
          items = {}
          findings = []
          list.each do |l|
            f = Validation.opaque(kind::OPAQUE_TYPE, l.body, rid)
            findings.concat(f.map { [_1, l] })
            next if f.any? { Validation.action(_1, @receive_policy) == :ignore_lsa }
            body = begin
              kind::Body.new(l.body)
            rescue Tlv::Error
              next
            end
            yield body, items, l.ls_id & 0xff_ffff
          end
          [rid, { items: items, findings: findings.map { |f, l| f.to_hash.merge(lsa: l.instance_fields.slice(:ls_id, :advr).merge(type: l.type)) } }]
        end
      end

      # Our opaque LSAs in +area+: its type 10s, and the type 11s while it
      # is the first area that takes externals.
      def opaque_specs_for(area)
        @opaque_specs.filter_map do |(aid, _), spec|
          spec if aid == area.id || (aid.nil? && opaque_area(nil).equal?(area))
        end
      end

      def opaque_spec(area, key) = @opaque_specs[[key[0] == 11 ? nil : area.id, key]]

      # The area an opaque LSA of ours goes into; for a type 11 (+aid+
      # nil), any area that takes externals, as for type 5.
      def opaque_area(aid) = aid ? @areas[aid] : @areas.values.find(&:external_capable?)

      # Every type 9 we hold: [interface, LSA].
      def link_database
        @interfaces.values.flat_map { |i| i.link_lsdb.map { |l| [i, l] } }
      end

      # ---- scopes ----

      # The database for LSA +type+ in +area+; nil if none (externals in a
      # stub area, RFC 2328 3.6; opaque while opaque is off). A type 9's
      # is its interface's (RFC 5250 section 3.1).
      def lsdb_for(type, area, iface = nil)
        return nil if OPAQUE.include?(type) && !@opaque
        return iface&.link_lsdb if type == 9
        return (area&.external_capable? == false ? nil : @as_lsdb) if AS_SCOPE.include?(type)
        return (area.nssa? ? area.lsdb : nil) if type == 7
        return area.lsdb if AREA_SCOPE.include?(type)
        nil
      end

      # Why an LSA of +type+ received on +iface+ has no database: the
      # Validation rule and the text. Every policy drops it (validation.rb).
      def unstored(type, iface)
        return [:as_external_over_virtual_link, 'type 11 opaque LSA over a virtual link'] if type == 11 && iface.virtual?
        # RFC 5250 section 3.1, opaque on or off.
        return [:opaque_as_in_stub, 'type 11 opaque LSA in a stub area or NSSA'] if type == 11 && !iface.area.external_capable?
        return [:unsupported_lsa_type, "unsupported type #{type}, opaque is off"] if OPAQUE.include?(type) && !@opaque
        if AS_SCOPE.include?(type)
          return iface.virtual? ? [:as_external_over_virtual_link, 'AS-external LSA over a virtual link'] :
                                  [:as_external_in_stub, 'AS-external LSA in a stub area or NSSA']
        end
        return [:nssa_outside_nssa, 'type 7 LSA outside an NSSA'] if type == 7
        [:unsupported_lsa_type, "unsupported type #{type}"]
      end

      # The overrun Validation finds in an opaque LSA ospfd reads (RI,
      # extended prefix, extended link), or nil. Its action is :drop_lsa
      # under every policy.
      def malformed(lsa)
        f = Validation.opaque(lsa.ls_id >> 24, lsa.body, Addr.to_s(lsa.advr)).find { _1.name == :tlv_overrun }
        f && "malformed #{lsa.id_string}: #{f.detail}"
      end

      # Databases summarized in DDs; AS-external LSAs never go over
      # virtual links (RFC 2328 10.3). RFC 5250 section 3.2 adds the
      # interface's type 9s, and types 10 and 11 with the others; the
      # neighbor's summary leaves opaque out when it does not set O.
      def lsdbs_for(area, virtual: false, iface: nil)
        dbs = area.external_capable? && !virtual ? [area.lsdb, @as_lsdb] : [area.lsdb]
        @opaque && iface ? dbs + [iface.link_lsdb] : dbs
      end

      def scope_interfaces(type, area, iface = nil)
        return iface ? [iface] : [] if type == 9
        return area.interfaces unless AS_SCOPE.include?(type)
        @interfaces.values.select { |i| i.area.external_capable? && !i.virtual? }
      end

      # ---- hooks from interfaces and neighbors ----

      def neighbor_changed(nbr, old, new)
        nbr.iface.forget(nbr) if new == :down
        if old == :full || new == :full
          # Our Adj-SIDs follow the router-LSA's links (Area#sr_specs).
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
          db = lsdb_for(lsa.type, area, iface)
          db = nil if iface.virtual? && AS_SCOPE.include?(lsa.type)
          unless db
            finding, why = unstored(lsa.type, iface)
            iface.drop(:lsa, "#{why} from #{nbr}", finding: finding)
            next
          end
          # RFC 7684 section 5, RFC 8665 section 9: a TLV past its end
          # makes the LSA malformed; it is not stored, acknowledged or
          # reflooded.
          if OPAQUE.include?(lsa.type) && (bad = malformed(lsa))
            iface.drop(:lsa, "#{bad} from #{nbr}", finding: :tlv_overrun)
            next
          end
          cur = db[lsa.key]

          # (4) A MaxAge LSA we do not have, with nobody mid-exchange.
          if lsa.max_age? && cur.nil? && !exchanging?(lsa.type, area, iface)
            iface.direct_ack(lsa, nbr)
            next
          end

          if cur.nil? || lsa.newer_than?(cur)
            # (5a) Too soon after the last one.
            next if cur && db.since_installed(lsa.key) < OSPFv2::MinLSArrival && lsa.advr != @router_id

            flooded_back = flood(lsa, area, from: nbr)
            drop_old_retransmits(lsa, area, iface)
            arriving(source: 'neighbor', router_id: Addr.to_s(nbr.router_id), address: Addr.to_s(nbr.address),
                     interface: iface.name) { db.install(lsa) }
            @stats[:lsa_installed] += 1
            unless flooded_back
              iface.delayed_ack(lsa) if !iface.backup? || nbr.address == iface.dr
            end
            self_originated(lsa, area, iface) if self_originated?(lsa)
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
            sk = scope_key(area, lsa.key, iface)
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
      # when it went back out of the receiving interface. A type 9 floods
      # on +iface+, or on the interface it came in on. An opaque LSA goes
      # on the lists of neighbors that set O only (RFC 5250 section 3.1).
      def flood(lsa, area, from: nil, iface: nil)
        flooded_back = false
        opaque = OPAQUE.include?(lsa.type)
        scope_interfaces(lsa.type, area, iface || from&.iface).each do |iface|
          next unless iface.up? && !iface.passive?
          added = false
          iface.neighbors.values.each do |n|
            next unless n.at_least?(:exchange)
            next if opaque && !n.opaque?
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
        options |= O_BIT if OPAQUE.include?(spec[:type])
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

      # Every LSA we hold but type 9s (link_database), with its area (nil
      # for AS scope).
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
        table = Spf.run(router_id: @router_id, areas: spf_areas, externals: @as_lsdb.live.select { _1.type == 5 },
                         max_paths: @max_paths)
        @stats[:spf_runs] += 1
        # Our summaries and externals that this run re-originates are told
        # in the topology events at its end, not one by one.
        @computing = true
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
        @computing = false
        @areas.each_value { |a| topology_changed(a) }
        topology_changed(nil)
        table
      ensure
        @computing = false
      end

      # Tells readers of show.topology to read again: one area (or the AS
      # scope, +area+ nil). After each SPF run, and after a change to our
      # own summaries and externals, which run no SPF.
      def topology_changed(area)
        where = area ? { area: area.id_s } : { scope: 'as' }
        publish(:info, "topology #{area ? "area #{area.id_s}" : 'AS scope'} changed", kind: :topology,
                                                                                      run: @spf.runs, **where)
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
          specs[[3, ls_id, @router_id]] = { type: 3, ls_id: ls_id, body: [Addr.mask(r.prefix_len), r.cost].pack('NN'),
                                            dest: r.dest_s }
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

      def lsdb_changed(lsa, _old, area = nil)
        return unless @running
        # Opaque LSAs run no SPF: only the label table reads them.
        return schedule_labels if OPAQUE.include?(lsa.type)
        # SPF never uses our own summaries and externals: no run for them,
        # but show.topology lists them.
        if lsa.advr == @router_id && [3, 4, 5, 7].include?(lsa.type)
          topology_changed(area) unless @computing
          return
        end
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
        compute_labels(notify: diff.empty?)
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
        # The SPF run below tells readers about the areas left; this one
        # is gone, so it is told here.
        topology_changed(area) if @running && !@computing
        @spf.trigger(:area, area.id_s) if @running
      end

      # An LSA key made unique across areas: [area id or nil for AS scope, *key].
      def lsa_owner(sk)
        area, type, ls_id, advr = sk
        { kind: 'lsa', area: area && Addr.to_s(area), type: type, ls_id: Addr.to_s(ls_id), advr: Addr.to_s(advr) }
      end

      def scope_key(area, key, iface = nil)
        return ["link #{iface&.name}", *key] if key[0] == 9
        [AS_SCOPE.include?(key[0]) ? nil : area.id, *key]
      end

      # Where our own LSA of +type+ lives: the AS database for externals,
      # whatever the area (it may have become a stub or NSSA since), else
      # the area's.
      def own_db(type, area) = AS_SCOPE.include?(type) ? @as_lsdb : area.lsdb

      # The database an LSA of +type+ is in: +iface+'s for a type 9.
      def db_of(type, area, iface) = type == 9 ? iface.link_lsdb : own_db(type, area)

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

      def flush(cur, area, iface = nil)
        lsa = cur.with_age(OSPFv2::MaxAge)
        arriving(source: lsa.advr == @router_id ? 'self' : 'flush') { db_of(lsa.type, area, iface).install(lsa) }
        # A flush is a new instance too: the next origination waits
        # MinLSInterval, or routers two hops away drop it (13 step 5a).
        @last_origination[scope_key(area, lsa.key, iface)] = @loop.now if lsa.advr == @router_id
        log(:info, nil, "flushing #{lsa.id_string}", kind: :lsa, change: 'flush', **lsa.instance_fields)
        drop_old_retransmits(lsa, area, iface)
        flood(lsa, area, iface: iface)
      end

      # RFC 2328 13.4: one of our own LSAs came back newer than ours.
      def self_originated(lsa, area, iface = nil)
        key = lsa.key
        sk = scope_key(area, key, iface)
        if lsa.advr == @router_id && area.wants?(key) && !@own.dig(sk, :wrap)
          # Jump past the sequence number that came back, now rather than
          # after MinLSInterval.
          @own[sk] ||= { area: area, key: key }
          @deferred.delete(sk)&.cancel
          @last_origination.delete(sk)
          originate(area, area.spec_for(key), force: true)
        elsif !lsa.max_age?
          flush(lsa, area, iface)
        end
      end

      def self_originated?(lsa)
        lsa.advr == @router_id || (lsa.type == 2 && @interfaces.each_value.any? { |i| i.address == lsa.ls_id })
      end

      def exchanging?(type, area, iface = nil)
        scope_interfaces(type, area, iface).any? do |i|
          i.neighbors.each_value.any? { |n| %i[exchange loading].include?(n.state) }
        end
      end

      # RFC 2328 13 (5c): older instances of this LSA leave every
      # retransmission list.
      def drop_old_retransmits(lsa, area, iface = nil)
        scope_interfaces(lsa.type, area, iface).each do |i|
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
        @interfaces.each_value { |i| sweep_db(i.link_lsdb, i.area, i) if i.link_lsdb.size.positive? }
      end

      def sweep_db(db, area, iface = nil)
        db.max_age_entries.each do |e|
          key = e.key
          if e.lsa.age < OSPFv2::MaxAge && !e.aged_out
            e.aged_out = true
            log(:info, nil, "#{e.lsa.id_string} reached MaxAge", kind: :lsa, change: 'maxage', **e.lsa.instance_fields)
            @spf.trigger(:maxage, e.lsa.id_string, lsa: e.lsa.instance_fields.merge(type: e.lsa.type, age: e.lsa.age),
                                                   source: { source: 'maxage' })
            flood(db.current(e), area, iface: iface)
          end
          next if exchanging?(key[0], area, iface)
          next if scope_interfaces(key[0], area, iface).any? { |i| i.neighbors.each_value.any? { |n| n.retransmitting?(key) } }
          db.delete(key)
          if (o = @own[scope_key(area, key, iface)]) && o[:wrap]
            @own.delete(scope_key(area, key, iface))
            spec = area.spec_for(key)
            originate(area, spec) if spec
          end
        end
      end
    end
  end
end
