# frozen_string_literal: true

require 'time'

module OSPFv2
  class Daemon
    # Operational state as plain data (Hashes, Arrays, Strings, Integers),
    # ready for JSON. ospf-cli formats it Junos or IOS style.
    #
    # Every method reads the router on the loop thread.
    class Views
      def initialize(daemon)
        @daemon = daemon
      end

      def overview
        on_loop do |r|
          base = { router_id: r&.router_id_s, started_at: @daemon.started_at&.utc&.iso8601,
                   uptime: uptime, pending: @daemon.pending.dup, configured: !r.nil? }
          next base unless r
          states = r.neighbors.map(&:state).tally
          base.merge(
            areas: r.areas.values.map do |a|
              { area: a.id_s, interfaces: a.interfaces.size,
                full_neighbors: a.interfaces.sum { |i| i.full_neighbors.size },
                lsas: a.lsdb.size, checksum_sum: format('0x%x', a.lsdb.sum(&:checksum)) }
            end,
            neighbors: { total: r.neighbors.size, full: states.fetch(:full, 0) },
            external_lsas: r.as_lsdb.size, abr: r.abr?, asbr: r.asbr?, exported: r.externals.size,
            spf: { runs: r.spf.runs, last_ago: r.spf_log.last && ago(r.spf_log.last.time), routes: r.routes.size },
            fib: fib_summary,
            lsa_originated: r.stats[:lsa_originated], lsa_installed: r.stats[:lsa_installed]
          )
        end
      end

      def neighbors
        on_loop do |r|
          next [] unless r
          r.neighbors.map do |n|
            i = n.iface
            n.summary.merge(area: i.area.id_s, role: role(i, n.address), dead_in: n.dead_in&.ceil)
          end
        end
      end

      def interfaces
        on_loop do |r|
          rows = r ? r.interfaces.values.map { |i| interface(r, i) } : []
          rows + @daemon.pending.map { |name, why| { name: name, state: :pending, reason: why } }
        end
      end

      # One row per LSA. +detail+ adds the decoded body of router and
      # network LSAs.
      def database(detail: false)
        on_loop do |r|
          next [] unless r
          r.database.map do |area, l|
            row = { area: area&.id_s, scope: area ? :area : :as, type: l.type, type_name: l.type_name,
                    ls_id: Core::Addr.to_s(l.ls_id), advr: Core::Addr.to_s(l.advr),
                    seq: format('0x%08x', l.seq & 0xffff_ffff), age: l.age, options: format('0x%02x', l.options),
                    checksum: format('0x%04x', l.checksum), length: l.length, self: l.advr == r.router_id }
            row[:detail] = l.detail if detail
            row
          end
        end
      end

      # The routing table: network routes and the ABRs and ASBRs used to
      # reach the rest.
      def routes
        on_loop do |r|
          next { routes: [], routers: [] } unless r
          t = r.route_table
          { routes: t.routes.values.sort_by { |x| [x.prefix, x.prefix_len] }.map { |x| route(x) },
            routers: t.routers.values.sort_by { |x| [x.prefix, x.area || 0] }.map do |x|
              route(x).merge(router_id: Core::Addr.to_s(x.prefix), abr: x.tag[:abr], asbr: x.tag[:asbr])
            end }
        end
      end

      # Our routes in the kernel against what OSPF wants there. The kernel
      # is read now, so drift shows.
      def fib
        on_loop do |r|
          k = @daemon.kernel_settings
          f = @daemon.fib
          base = { configured: !r.nil?, install: k ? k[:install] : true, error: @daemon.fib_error,
                   protocol: k&.dig(:protocol), table: k&.dig(:table), metric: k&.dig(:metric) }
          next base.merge(routes: []) unless f && r
          rib = r.routes
          rows = f.status(fresh: true).map do |e|
            x = rib[e.key[0, 2]]
            { prefix: (e.want || e.have).dest_s, state: e.state, error: e.error, metric: e.key[2],
              want: e.want && fib_hops(e.want), have: e.have && fib_hops(e.have),
              path_type: x&.path_type, cost: x&.cost, type2_cost: x&.type2_cost }
          end
          base.merge(holding: f.holding?, repairs: f.repairs, last_reconcile: f.last_reconcile&.utc&.iso8601,
                     routes: rows)
        end
      end

      # SPF state and the last runs, newest last.
      def spf(count = 100)
        on_loop do |r|
          next { configured: false } unless r
          s = r.spf
          { configured: true, state: s.state, runs: s.runs, routes: r.routes.size,
            next_run_in: s.next_run_in&.round(3),
            settings: s.settings.transform_values { |v| (v * 1000).round },
            log: r.spf_log.last(count).map do |x|
              { time: x.time.utc.iso8601, ago: ago(x.time), duration_ms: (x.duration * 1000).round(3),
                routes: x.routes, added: x.diff.added.size, changed: x.diff.changed.size,
                removed: x.diff.removed.size, reasons: x.reasons.map { |y| { kind: y.kind, detail: y.detail } } }
            end }
        end
      end

      NEAR_MAXAGE = 300 # seconds: LSAs this close to MaxAge are listed
      NEAR_MAXAGE_MAX = 50

      # Every timer of the router and the daemon: what it belongs to, when
      # it fires next, its period, how often it fired. Timers nobody claims
      # come last, kind 'other'. With them, what checking them needs: each
      # interface's intervals, each neighbor's lists, the LSAs nearest
      # MaxAge, the protocol constants and SPF's state.
      def timers
        on_loop do |r|
          wall = @daemon.loop.clock.wall
          rows = []
          seen = {}.compare_by_identity
          add = lambda do |owner, name, t|
            next if t.nil? || seen[t]
            seen[t] = true
            rows << timer_row(owner, name, t, wall)
          end
          r&.timers&.each { |o, n, t| add.(o, n, t) }
          @daemon.timers.each { |n, t| add.({ kind: 'daemon' }, n, t) }
          @daemon.fib&.timers&.each { |n, t| add.({ kind: 'fib' }, n, t) }
          @daemon.loop.scheduler.armed.each { |t| add.({ kind: 'other' }, t.name, t) }
          { time: wall.utc.iso8601(3), timers: rows, interfaces: r ? timer_interfaces(r) : [],
            neighbors: r ? timer_neighbors(r) : [], near_maxage: r ? near_maxage(r) : [],
            constants: { min_ls_interval: OSPFv2::MinLSInterval, min_ls_arrival: OSPFv2::MinLSArrival,
                         ls_refresh_time: OSPFv2::LSRefreshTime, max_age: OSPFv2::MaxAge },
            spf: r ? { state: r.spf.state, settings: r.spf.settings.transform_values { |v| (v * 1000).round } } : nil }
        end
      end

      # Recent events, debug ones left out.
      def log(count = 100)
        on_loop do |r|
          next [] unless r
          r.events.reject { |e| e.level == :debug }.last(count).map { |e| { time: e.time.utc.iso8601, level: e.level, interface: e.interface, message: e.message } }
        end
      end

      def statistics
        on_loop do |r|
          next {} unless r
          r.interfaces.values.to_h { |i| [i.name, i.stats.sort.to_h] }
        end
      end

      private

      def on_loop(&block)
        @daemon.loop.call { block.call(@daemon.instance) }
      end

      def timer_row(owner, name, t, wall)
        rem = t.remaining
        { name: name.to_s, owner: owner, armed: t.active?, due_in: rem&.round(3),
          due_at: rem && (wall + rem).utc.iso8601(3), interval: t.interval, periodic: t.periodic?, fired: t.fired }
      end

      def timer_interfaces(r)
        r.interfaces.values.map do |i|
          { name: i.name, state: i.state, hello_interval: i.hello_interval, dead_interval: i.dead_interval,
            rxmt_interval: i.rxmt_interval, transmit_delay: i.transmit_delay }
        end
      end

      def timer_neighbors(r)
        r.interfaces.values.flat_map do |i|
          i.neighbors.values.map do |n|
            { interface: i.name, router_id: Core::Addr.to_s(n.router_id), address: Core::Addr.to_s(n.address),
              state: n.state, retransmit: n.retransmit.size, requests: n.ls_request.size }
          end
        end
      end

      def near_maxage(r)
        r.database.select { |_, l| l.age >= OSPFv2::MaxAge - NEAR_MAXAGE }.sort_by { |_, l| -l.age }.first(NEAR_MAXAGE_MAX).map do |area, l|
          { area: area&.id_s, type: l.type, ls_id: Core::Addr.to_s(l.ls_id), advr: Core::Addr.to_s(l.advr), age: l.age,
            max_age_in: [OSPFv2::MaxAge - l.age, 0].max }
        end
      end

      def ago(time) = (@daemon.loop.clock.wall - time).floor

      def fib_hops(route) = route.next_hops.map { |i, g| { interface: i, gateway: g && Core::Addr.to_s(g) } }

      def route(x)
        { prefix: x.dest_s, path_type: x.path_type, cost: x.cost, type2_cost: x.type2_cost, area: x.area_s,
          next_hops: x.next_hops.map { |h| { interface: h.interface, gateway: h.gateway && Core::Addr.to_s(h.gateway) } },
          advr: x.advr && Core::Addr.to_s(x.advr), tag: x.tag.is_a?(Integer) ? x.tag : nil,
          forwarding: x.forwarding && Core::Addr.to_s(x.forwarding) }
      end

      def fib_summary
        k = @daemon.kernel_settings
        return { install: false } if k && !k[:install]
        return { install: true, error: @daemon.fib_error } unless @daemon.fib
        states = @daemon.fib.status.map(&:state).tally
        { install: true, installed: states.fetch(:installed, 0), failed: states.fetch(:failed, 0),
          held: states.fetch(:held, 0), protocol: k[:protocol], table: k[:table] }
      end

      def uptime
        s = @daemon.started_at
        s ? (@daemon.loop.clock.wall - s).floor : 0
      end

      # A neighbor's role on a segment, as IOS prints it after FULL/.
      def role(iface, address)
        return '-' if iface.p2p?
        return 'DR' if address == iface.dr
        return 'BDR' if address == iface.bdr
        'DROTHER'
      end

      def interface(r, i)
        s = i.summary
        s.merge(dr_id: router_id_at(r, i, i.dr), bdr_id: router_id_at(r, i, i.bdr),
                state_name: state_name(i), role: role(i, i.address))
      end

      # Router id behind a DR/BDR address on +iface+.
      def router_id_at(r, iface, address)
        return '0.0.0.0' if address.zero?
        return r.router_id_s if address == iface.address
        n = iface.neighbors.values.find { |x| x.address == address }
        n ? Core::Addr.to_s(n.router_id) : Core::Addr.to_s(address)
      end

      def state_name(i)
        { down: 'Down', loopback: 'Loopback', waiting: 'Waiting', point_to_point: 'PtToPt',
          dr_other: 'DROther', backup: 'BDR', dr: 'DR' }.fetch(i.state, i.state.to_s)
      end
    end
  end
end
