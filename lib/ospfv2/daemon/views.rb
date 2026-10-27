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
            external_lsas: r.as_lsdb.size,
            spf: { runs: r.spf.runs, last_ago: r.spf_log.last && ago(r.spf_log.last.time), routes: r.routes.size },
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
            row[:detail] = body(l) if detail
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

      def ago(time) = (@daemon.loop.clock.wall - time).floor

      def route(x)
        { prefix: x.dest_s, path_type: x.path_type, cost: x.cost, type2_cost: x.type2_cost, area: x.area_s,
          next_hops: x.next_hops.map { |h| { interface: h.interface, gateway: h.gateway && Core::Addr.to_s(h.gateway) } },
          advr: x.advr && Core::Addr.to_s(x.advr), tag: x.tag.is_a?(Integer) ? x.tag : nil,
          forwarding: x.forwarding && Core::Addr.to_s(x.forwarding) }
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

      def body(l)
        case l.type
        when 1
          flags, links = l.router_body
          { flags: { b: flags[0] == 1, e: flags[1] == 1, v: flags[2] == 1 },
            links: links.map { |k| { type: k.type_name, id: Core::Addr.to_s(k.id), data: Core::Addr.to_s(k.data), metric: k.metric } } }
        when 2
          mask, routers = l.network_body
          { mask: Core::Addr.to_s(mask), attached: routers.map { |x| Core::Addr.to_s(x) } }
        when 3, 4, 5
          b = l.body
          mask, metric = b.unpack('NN')
          d = { mask: Core::Addr.to_s(mask), metric: metric & 0xff_ffff }
          if l.type == 5 && b.bytesize >= 16
            _, _, fwd, tag = b.unpack('NNNN')
            d.merge!(external_type: metric >> 31 == 1 ? 2 : 1, forwarding: Core::Addr.to_s(fwd), tag: tag)
          end
          d
        else {}
        end
      rescue Core::Lsa::Error => e
        { error: e.message }
      end
    end
  end
end
