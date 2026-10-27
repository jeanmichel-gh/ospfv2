# frozen_string_literal: true

module OSPFv2
  module CommandLine
    # Turns the daemon's views (plain Hashes from the API, string keys)
    # into the tables a Junos or IOS user expects.
    module Format
      module_function

      def render(view, style, data, detail: false, type: nil, router_id: nil)
        case view
        when :neighbors then style == :ios ? ios_neighbors(data, detail) : junos_neighbors(data, detail)
        when :interfaces then style == :ios ? ios_interfaces(data, detail, router_id) : junos_interfaces(data, detail)
        when :database
          data = data.select { |r| r['type'] == type } if type
          style == :ios ? ios_database(data, router_id) : junos_database(data, detail)
        when :overview then style == :ios ? ios_overview(data) : junos_overview(data)
        when :log then log(data)
        when :statistics then statistics(data)
        when :routes
          case style
          when :ios then ios_routes(data)
          when :ios_rib then ios_rib(data)
          else junos_routes(data, detail)
          end
        when :spf then style == :ios ? ios_spf(data, router_id) : junos_spf(data)
        else data.to_s
        end
      end

      # ---- neighbors ----

      def junos_neighbors(rows, detail)
        out = [row(%w[Address Interface State ID Pri Dead], [17, 23, 10, 17, -4, -5])]
        rows.each do |n|
          out << row([n['address'], n['interface'], cap(n['state']), n['router_id'], n['priority'], n['dead_in']],
                     [17, 23, 10, 17, -4, -5])
          next unless detail
          out << "  Area #{n['area']}, DR #{n['dr']}, BDR #{n['bdr']}, role #{n['role']}"
          out << "  Up #{duration(n['uptime'])}, #{n['state_changes']} state changes"
          out << "  Requests #{n['ls_request']}, retransmissions #{n['retransmit']}, summary #{n['db_summary']}"
        end
        out.join("\n")
      end

      def ios_neighbors(rows, detail)
        if detail
          return rows.map do |n|
            [" Neighbor #{n['router_id']}, interface address #{n['address']}",
             "    In the area #{n['area']} via interface #{n['interface']}",
             "    Neighbor priority is #{n['priority']}, State is #{ios_state(n)}, #{n['state_changes']} state changes",
             "    DR is #{n['dr']} BDR is #{n['bdr']}",
             "    Dead timer due in #{clock(n['dead_in'])}",
             "    Neighbor is up for #{clock(n['uptime'])}",
             "    Link State retransmission list length #{n['retransmit']}, request list length #{n['ls_request']}"].join("\n")
          end.join("\n\n")
        end
        out = [format('%-16s%3s   %-16s%-12s%-16s%s', 'Neighbor ID', 'Pri', 'State', 'Dead Time', 'Address', 'Interface')]
        rows.each do |n|
          out << format('%-16s%3s   %-16s%-12s%-16s%s', n['router_id'], n['priority'], ios_state(n),
                        clock(n['dead_in']), n['address'], n['interface'])
        end
        out.join("\n")
      end

      def ios_state(n)
        s = { 'two_way' => '2WAY', 'exstart' => 'EXSTART', 'exchange' => 'EXCHANGE', 'loading' => 'LOADING',
              'full' => 'FULL', 'init' => 'INIT', 'down' => 'DOWN', 'attempt' => 'ATTEMPT' }.fetch(n['state'].to_s, n['state'].to_s.upcase)
        "#{s}/#{n['role'] == '-' ? ' -' : n['role']}"
      end

      # ---- interfaces ----

      def junos_interfaces(rows, detail)
        widths = [20, 8, 16, 16, 16, -4]
        out = [row(['Interface', 'State', 'Area', 'DR ID', 'BDR ID', 'Nbrs'], widths)]
        rows.each do |i|
          if i['state'] == 'pending'
            out << row([i['name'], 'Pending', '', '', '', ''], widths)
            out << "  #{i['reason']}"
            next
          end
          state = i['passive'] ? 'Passive' : i['state_name']
          out << row([i['name'], state, i['area'], i['dr_id'], i['bdr_id'], i['neighbors']], widths)
          next unless detail
          addr, len = i['address'].split('/')
          out << "  Type: #{i['type'] == 'p2p' ? 'P2P' : 'LAN'}, Address: #{addr}, Mask: #{mask(len.to_i)}, " \
                 "MTU: #{i['mtu']}, Cost: #{i['cost']}"
          if i['passive']
            out << '  Passive: no hellos, advertised as a stub network'
            next
          end
          out << "  DR addr: #{i['dr']}, BDR addr: #{i['bdr']}, Priority: #{i['priority']}" unless i['type'] == 'p2p'
          out << "  Adj count: #{i['adjacent']}"
          out << "  Hello: #{i['hello_interval']}, Dead: #{i['dead_interval']}, ReXmit: #{i['rxmt_interval']}"
          out << "  Auth: #{i['auth']}"
        end
        out.join("\n")
      end

      def ios_interfaces(rows, detail, router_id)
        unless detail
          out = [format('%-13s%-6s%-16s%-19s%-6s%-6s%s', 'Interface', 'PID', 'Area', 'IP Address/Mask', 'Cost', 'State', 'Nbrs F/C')]
          rows.each do |i|
            next out << format('%-13s%-6s%-16s%-19s%-6s%-6s%s', i['name'], 1, '', '', '', 'PEND', '') if i['state'] == 'pending'
            out << format('%-13s%-6s%-16s%-19s%-6s%-6s%s', i['name'], 1, ios_area(i['area']), i['address'], i['cost'],
                          i['passive'] ? 'LOOP' : ios_if_state(i), "#{i['adjacent']}/#{i['neighbors']}")
          end
          return out.join("\n")
        end
        rows.map do |i|
          next "#{i['name']} is not running OSPF: #{i['reason']}" if i['state'] == 'pending'
          lines = ["#{i['name']} is up, line protocol is up",
                   "  Internet Address #{i['address']}, Area #{ios_area(i['area'])}",
                   "  Process ID 1, Router ID #{router_id}, Network Type #{i['type'] == 'p2p' ? 'POINT_TO_POINT' : 'BROADCAST'}, Cost: #{i['cost']}"]
          if i['passive']
            lines << '  No Hellos (Passive interface)'
          else
            lines << "  Transmit Delay is 1 sec, State #{ios_if_state(i)}, Priority #{i['priority']}"
            unless i['type'] == 'p2p'
              lines << "  Designated Router (ID) #{i['dr_id']}, Interface address #{i['dr']}"
              lines << "  Backup Designated router (ID) #{i['bdr_id']}, Interface address #{i['bdr']}"
            end
            lines << "  Timer intervals configured, Hello #{i['hello_interval']}, Dead #{i['dead_interval']}, " \
                     "Wait #{i['dead_interval']}, Retransmit #{i['rxmt_interval']}"
            lines << "    Hello due in #{clock(i['hello_due']&.ceil)}" if i['hello_due']
            lines << "  Neighbor Count is #{i['neighbors']}, Adjacent neighbor count is #{i['adjacent']}"
          end
          lines << (i['auth'] == 'none' ? '  No authentication' : "  Authentication: #{i['auth']}")
          lines.join("\n")
        end.join("\n")
      end

      def ios_if_state(i)
        { 'DROther' => 'DROTH', 'PtToPt' => 'P2P', 'Waiting' => 'WAIT', 'Down' => 'DOWN' }.fetch(i['state_name'], i['state_name'])
      end

      # ---- database ----

      JUNOS_TYPES = { 1 => 'Router', 2 => 'Network', 3 => 'Summary', 4 => 'ASBRSum', 5 => 'Extern' }.freeze

      def junos_database(rows, detail)
        out = []
        rows.group_by { |r| r['area'] }.each do |area, lsas|
          out << ''
          out << (area ? "    OSPF database, Area #{area}" : '    OSPF AS SCOPE link state database')
          out << ' Type       ID               Adv Rtr           Seq      Age  Opt  Cksum  Len'
          lsas.sort_by { |r| [r['type'], ip(r['ls_id']), ip(r['advr'])] }.each do |r|
            out << format('%-8s%s%-17s%-17s%-11s%5d  %-4s %-6s %3d', JUNOS_TYPES.fetch(r['type'], r['type'].to_s),
                          r['self'] ? '*' : ' ', r['ls_id'], r['advr'], r['seq'], r['age'], r['options'],
                          r['checksum'], r['length'])
            out.concat(junos_detail(r)) if detail
          end
        end
        out.join("\n")
      end

      def junos_detail(r)
        d = r['detail'] or return []
        case r['type']
        when 1
          flags = d['flags'].select { |_, v| v }.keys.map(&:upcase)
          ["  bits 0x#{format('%x', (d['flags']['b'] ? 1 : 0) | (d['flags']['e'] ? 2 : 0) | (d['flags']['v'] ? 4 : 0))}" \
           "#{flags.empty? ? '' : " (#{flags.join(' ')})"}, link count #{d['links'].size}"] +
            d['links'].map { |l| "  id #{l['id']}, data #{l['data']}, Type #{l['type'].capitalize} (#{link_code(l['type'])})\n    Topology count: 0, Default metric: #{l['metric']}" }
        when 2
          ["  mask #{d['mask']}"] + d['attached'].map { |a| "  attached router #{a}" }
        when 3, 4, 5
          ["  mask #{d['mask']}", "  Topology default (ID 0)",
           "    #{r['type'] == 5 ? "Type: #{d['external_type']}, " : ''}Metric: #{d['metric']}" \
           "#{r['type'] == 5 ? ", Fwd addr: #{d['forwarding']}, Tag: #{d['tag']}" : ''}"]
        else []
        end
      end

      def link_code(type) = { 'p2p' => 1, 'transit' => 2, 'stub' => 3, 'virtual' => 4 }.fetch(type, '?')

      IOS_SECTIONS = { 1 => 'Router Link States', 2 => 'Net Link States', 3 => 'Summary Net Link States',
                       4 => 'Summary ASB Link States', 5 => 'Type-5 AS External Link States' }.freeze

      def ios_database(rows, router_id)
        out = ['', "            OSPF Router with ID (#{router_id}) (Process ID 1)"]
        rows.group_by { |r| [r['type'], r['area']] }.sort_by { |(t, a), _| [a ? 0 : 1, a.to_s, t] }.each do |(type, area), lsas|
          out << ''
          out << "                #{IOS_SECTIONS.fetch(type, "Type-#{type}")}#{area ? " (Area #{ios_area(area)})" : ''}"
          out << ''
          last = { 1 => 'Link count', 5 => 'Tag' }.fetch(type, '')
          out << format('%-16s%-16s%-12s%-11s%-9s%s', 'Link ID', 'ADV Router', 'Age', 'Seq#', 'Checksum', last).rstrip
          lsas.sort_by { |r| [ip(r['ls_id']), ip(r['advr'])] }.each do |r|
            extra = case type
                    when 1 then r.dig('detail', 'links')&.size
                    when 5 then r.dig('detail', 'tag')
                    end
            out << format('%-16s%-16s%-12d%-11s0x%06X %s', r['ls_id'], r['advr'], r['age'], r['seq'],
                          r['checksum'].to_i(16), extra).rstrip
          end
        end
        out.join("\n")
      end

      # ---- overview ----

      def junos_overview(o)
        return 'OSPF is not configured (set routing-options router-id and an interface)' unless o['configured']
        out = ['Instance: master', "  Router ID: #{o['router_id']}", "  Up: #{duration(o['uptime'])}"]
        o['areas'].each do |a|
          out << "  Area: #{a['area']}"
          out << "    Interfaces: #{a['interfaces']}, LSAs: #{a['lsas']}, checksum sum #{a['checksum_sum']}"
          out << '    Neighbors'
          out << "      Up (in full state): #{a['full_neighbors']}"
        end
        out << "  External LSAs: #{o['external_lsas']}"
        spf = o['spf'] || {}
        out << "  SPF: #{spf['runs'].to_i} runs#{spf['last_ago'] ? ", last #{duration(spf['last_ago'])} ago" : ''}, " \
               "#{spf['routes'].to_i} routes"
        o['pending'].each { |name, why| out << "  Interface #{name} not running: #{why}" }
        out.join("\n")
      end

      def ios_overview(o)
        return '%OSPF: not configured' unless o['configured']
        out = [" Routing Process \"ospf 1\" with ID #{o['router_id']}",
               " Time elapsed: #{clock(o['uptime'])}",
               " Number of external LSA #{o['external_lsas']}",
               " Number of areas in this router is #{o['areas'].size}"]
        o['areas'].each do |a|
          name = a['area'] == '0.0.0.0' ? 'BACKBONE(0)' : "#{ios_area(a['area'])}"
          out << "    Area #{name}"
          out << "        Number of interfaces in this area is #{a['interfaces']}"
          out << "        Number of fully adjacent neighbors in this area is #{a['full_neighbors']}"
          out << "        SPF algorithm executed #{o.dig('spf', 'runs').to_i} times"
          out << "        Number of LSA #{a['lsas']}. Checksum Sum #{a['checksum_sum']}"
        end
        o['pending'].each { |name, why| out << " Interface #{name} not running: #{why}" }
        out.join("\n")
      end

      # ---- routes ----

      PATH_TYPES = { 'intra' => 'Intra', 'inter' => 'Inter', 'ext1' => 'Ext1', 'ext2' => 'Ext2' }.freeze

      # Junos "show ospf route": routers first, then networks.
      def junos_routes(data, detail)
        widths = [18, 5, 11, 4, -6, 13]
        out = ['Topology default Route Table:', '',
               row(['Prefix', 'Path', 'Route', 'NH', 'Metric', 'NextHop', 'Nexthop'], widths),
               row(['', 'Type', 'Type', 'Type', '', 'Interface', 'Address/LSP'], widths)]
        rows = data['routers'].map { |r| [r, r['router_id'], router_kind(r)] } +
               data['routes'].map { |r| [r, r['prefix'], 'Network'] }
        rows.each do |r, dest, kind|
          metric = r['path_type'] == 'ext2' ? r['type2_cost'] : r['cost']
          hops = r['next_hops'].empty? ? [{ 'interface' => '', 'gateway' => nil }] : r['next_hops']
          hops.each_with_index do |h, i|
            cells = i.zero? ? [dest, PATH_TYPES.fetch(r['path_type'], r['path_type']), kind, 'IP', metric] : ['', '', '', '', '']
            out << row(cells + [h['interface'], h['gateway']], widths)
          end
          next unless detail
          d = [r['area'] && "area #{r['area']}", "origin #{r['advr']}"].compact
          d << "type 2 metric #{r['type2_cost']}, internal #{r['cost']}" if r['path_type'] == 'ext2'
          d << "fwd addr #{r['forwarding']}" if r['forwarding']
          d << "tag #{r['tag']}" if r['tag'].to_i.positive?
          out << "  #{d.join(', ')}"
        end
        out.join("\n")
      end

      def router_kind(r)
        "#{[('Area' if r['abr']), ('AS' if r['asbr'])].compact.join('/')} BR"
      end

      # "show ip ospf route", as FRR prints it.
      def ios_routes(data)
        nets, ext = data['routes'].partition { |r| %w[intra inter].include?(r['path_type']) }
        out = ['============ OSPF network routing table ============']
        nets.each do |r|
          out << format('%-4s %-18s    [%d] area: %s', r['path_type'] == 'inter' ? 'N IA' : 'N', r['prefix'], r['cost'], r['area'])
          out.concat(ios_hops(r))
        end
        out << '' << '============ OSPF router routing table ============='
        data['routers'].each do |r|
          kinds = [('ABR' if r['abr']), ('ASBR' if r['asbr'])].compact.join(', ')
          out << format('%-4s %-18s    [%d] area: %s, %s', r['path_type'] == 'inter' ? 'R IA' : 'R', r['router_id'],
                        r['cost'], r['area'], kinds)
          out.concat(ios_hops(r))
        end
        out << '' << '============ OSPF external routing table ==========='
        ext.each do |r|
          cost = r['path_type'] == 'ext2' ? "#{r['cost']}/#{r['type2_cost']}" : r['cost'].to_s
          out << format('%-4s %-18s    [%s] tag: %d', r['path_type'] == 'ext2' ? 'N E2' : 'N E1', r['prefix'], cost, r['tag'].to_i)
          out.concat(ios_hops(r))
        end
        out.join("\n")
      end

      def ios_hops(r)
        r['next_hops'].map do |h|
          (' ' * 27) + (h['gateway'] ? "via #{h['gateway']}, #{h['interface']}" : "directly attached to #{h['interface']}")
        end
      end

      IOS_CODES = { 'intra' => 'O', 'inter' => 'O IA', 'ext1' => 'O E1', 'ext2' => 'O E2' }.freeze

      # "show ip route ospf": what OSPF puts in the routing table.
      # Networks we are on stay connected routes and are left out.
      def ios_rib(data)
        out = ['Codes: O - OSPF, IA - OSPF inter area, E1 - OSPF external type 1, E2 - OSPF external type 2', '']
        data['routes'].each do |r|
          hops = r['next_hops']
          next if hops.empty? || hops.any? { |h| h['gateway'].nil? }
          metric = r['path_type'] == 'ext2' ? r['type2_cost'] : r['cost']
          lead = format('%-8s %s ', IOS_CODES.fetch(r['path_type'], 'O'), r['prefix'])
          hops.each_with_index do |h, i|
            out << "#{i.zero? ? lead : ' ' * lead.size}[110/#{metric}] via #{h['gateway']}, #{h['interface']}"
          end
        end
        out.join("\n")
      end

      # ---- SPF ----

      def junos_spf(s)
        return 'OSPF is not configured' unless s['configured']
        st = s['settings']
        out = ["SPF runs: #{s['runs']}, state: #{s['state'].tr('_', ' ')}, routes: #{s['routes']}, " \
               "next run: #{s['next_run_in'] ? "in #{(s['next_run_in'] * 1000).round} ms" : 'none'}",
               "Back-off (RFC 8405): initial #{st['initial']} ms, short #{st['short']} ms, long #{st['long']} ms, " \
               "learn #{st['learn']} ms, holddown #{st['holddown']} ms", '',
               format('%-20s %-10s %6s  %-11s %s', 'When', 'Elapsed', 'Routes', 'Changes', 'Trigger')]
        s['log'].each do |x|
          out << format('%-20s %-10.6f %6d  %-11s %s', x['time'].sub('T', ' ').sub('Z', ''), x['duration_ms'] / 1000.0,
                        x['routes'], "+#{x['added']} ~#{x['changed']} -#{x['removed']}",
                        x['reasons'].map { |y| [y['kind'], y['detail']].compact.join(' ') }.join(', '))
        end
        out.join("\n")
      end

      SPF_CODES = { 'router' => 'R', 'network' => 'N', 'summary' => 'SN', 'asbr_summary' => 'SA', 'external' => 'X',
                    'nssa' => 'X7', 'maxage' => 'MAXAGE', 'interface' => 'IF', 'neighbor' => 'NBR', 'area' => 'AREA',
                    'stop' => 'STOP', 'manual' => 'CLEAR', 'more' => '+' }.freeze

      # "show ip ospf statistics"
      def ios_spf(s, router_id)
        return '%OSPF: not configured' unless s['configured']
        out = ['', "            OSPF Router with ID (#{router_id}) (Process ID 1)", '',
               "  SPF algorithm executed #{s['runs']} times", '',
               '  SPF calculation time',
               format('%-10s %-8s %-7s %-10s %s', 'Delta T', 'Total', 'Routes', 'Changes', 'Reason')]
        s['log'].reverse_each do |x|
          codes = x['reasons'].map { |y| SPF_CODES.fetch(y['kind'], y['kind']) }.uniq
          out << format('%-10s %-8s %-7d %-10s %s', duration(x['ago']), x['duration_ms'].round, x['routes'],
                        "+#{x['added']} ~#{x['changed']} -#{x['removed']}", codes.join(', '))
        end
        out.join("\n")
      end

      # ---- log and statistics ----

      def log(rows)
        rows.map { |e| "#{e['time'].sub('T', ' ').sub('Z', '')} #{e['interface'] ? "#{e['interface']} " : ''}#{e['message']}" }.join("\n")
      end

      def statistics(stats)
        kinds = %w[hello dd ls_request ls_update ls_ack]
        out = []
        stats.each do |name, s|
          out << "Interface #{name}"
          out << format('  %-12s %10s %10s', 'Packet', 'Sent', 'Received')
          kinds.each { |k| out << format('  %-12s %10d %10d', k, s["tx_#{k}"] || 0, s["rx_#{k}"] || 0) }
          drops = s.select { |k, _| k.start_with?('drop_') }
          out << "  Dropped: #{drops.map { |k, v| "#{k.delete_prefix('drop_')} #{v}" }.join(', ')}" unless drops.empty?
        end
        out.join("\n")
      end

      # ---- helpers ----

      def row(cells, widths)
        cells.zip(widths).map do |c, w|
          next c.to_s if w.nil? || w.zero?
          w.negative? ? c.to_s.rjust(-w) : c.to_s.ljust(w)
        end.join(' ').rstrip
      end

      def cap(s) = s.to_s.split('_').map(&:capitalize).join('-').sub('Two-Way', '2Way')

      def duration(secs)
        s = secs.to_i
        d, s = s.divmod(86_400)
        h, s = s.divmod(3600)
        m, s = s.divmod(60)
        d.positive? ? format('%dd %02d:%02d:%02d', d, h, m, s) : format('%02d:%02d:%02d', h, m, s)
      end

      def clock(secs)
        return '-' if secs.nil?
        duration(secs)
      end

      def mask(len) = [len.zero? ? 0 : (0xffff_ffff << (32 - len)) & 0xffff_ffff].pack('N').unpack('C4').join('.')

      def ip(s) = s.to_s.split('.').map(&:to_i)

      # IOS shows area 0.0.0.N as N.
      def ios_area(a)
        n = ip(a).inject(0) { |acc, o| (acc << 8) | o }
        n < 256 * 256 * 256 ? n.to_s : a
      end
    end
  end
end
