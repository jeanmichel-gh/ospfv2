# frozen_string_literal: true

require_relative 'addr'
require_relative 'lsa'

module OSPFv2
  module Core
    # The routing table calculation of RFC 2328 section 16, as a pure
    # function: link state databases in, routes out. It touches no socket,
    # timer or kernel, so it can run on any database, from any root.
    #
    #   table = Spf.run(
    #     router_id: '1.1.1.1',
    #     areas: [Spf::Area.new(id: 0, lsas: [...],
    #                           interfaces: [Spf::Link.new(name: 'eth1', address: '10.0.12.1', prefix_len: 24)])],
    #     externals: [...]
    #   )
    #   table.routes   # => { [prefix, len] => Spf::Route }
    #   table.routers  # => ABRs and ASBRs, { [router_id, area] => Spf::Route }
    #
    # Covered: intra-area routes (16.1) with the two-way check, next hops
    # (16.1.1) and equal-cost multipath; inter-area routes (16.2);
    # AS external routes (16.4), type 1 and type 2, with forwarding
    # addresses. Not yet: virtual links (16.3), NSSA type 7 LSAs, area
    # address ranges, and the RFC 2328 16.4.1 preference rules (we behave
    # as RFC1583Compatibility enabled, the RFC 2328 default).
    module Spf
      LS_INFINITY = 0xff_ffff
      PATH_TYPES = %i[intra inter ext1 ext2].freeze

      # An OSPF interface of the calculating router: its name and address,
      # and optionally its neighbors' addresses by router id, used for a
      # point-to-point next hop when the neighbor's router-LSA does not
      # say its address on our subnet (an unnumbered link, say).
      Link = Struct.new(:name, :address, :prefix_len, :neighbors, keyword_init: true) do
        def initialize(name:, address:, prefix_len:, neighbors: {})
          super(name: name, address: Addr.to_i(address), prefix_len: prefix_len,
                neighbors: neighbors.to_h { |rid, ip| [Addr.to_i(rid), Addr.to_i(ip)] })
        end

        def mask = Addr.mask(prefix_len)
        def network = address & mask
        def on?(ip) = (ip & mask) == network
      end

      Area = Struct.new(:id, :lsas, :interfaces, keyword_init: true) do
        def initialize(id:, lsas:, interfaces: [])
          super(id: Addr.to_i(id), lsas: lsas, interfaces: interfaces)
        end
      end

      # Where traffic leaves: an interface, and the next router's address
      # (nil when the destination is on that interface's network).
      NextHop = Struct.new(:interface, :gateway) do
        def to_s = gateway ? "via #{Addr.to_s(gateway)} #{interface}" : "direct #{interface}"
        def sort_key = [interface.to_s, gateway || 0]
      end

      # One destination. +cost+ is the internal cost (for type 2 external
      # routes, the cost to the ASBR or forwarding address); +type2_cost+
      # is the type 2 metric. +advr+ is the router that advertised it.
      Route = Struct.new(:prefix, :prefix_len, :path_type, :cost, :type2_cost, :area, :next_hops,
                         :advr, :tag, :forwarding, keyword_init: true) do
        def dest_s = "#{Addr.to_s(prefix)}/#{prefix_len}"
        def area_s = area && Addr.to_s(area)

        # Same destination, same way to get there.
        def same_as?(o)
          o && path_type == o.path_type && cost == o.cost && type2_cost == o.type2_cost &&
            area == o.area && next_hops.sort_by(&:sort_key) == o.next_hops.sort_by(&:sort_key)
        end

        def to_s
          c = path_type == :ext2 ? "#{cost}/#{type2_cost}" : cost.to_s
          "#{dest_s} #{path_type} [#{c}] #{next_hops.map(&:to_s).join(', ')}"
        end
      end

      Table = Struct.new(:routes, :routers, :stats, keyword_init: true) do
        def self.empty = new(routes: {}, routers: {}, stats: { vertices: 0, areas: 0, skipped: [] })
      end

      # What changed between two route tables: Routes added and removed,
      # and [old, new] pairs for routes that changed.
      Diff = Struct.new(:added, :changed, :removed) do
        def empty? = added.empty? && changed.empty? && removed.empty?
        def to_s = "+#{added.size} ~#{changed.size} -#{removed.size}"
      end

      def self.diff(old, new)
        added = new.reject { |k, _| old.key?(k) }.values
        removed = old.reject { |k, _| new.key?(k) }.values
        changed = new.filter_map { |k, r| (o = old[k]) && !r.same_as?(o) ? [o, r] : nil }
        Diff.new(added, changed, removed)
      end

      # Runs the whole calculation. +max_paths+ caps equal-cost next hops.
      def self.run(router_id:, areas:, externals: [], max_paths: 16)
        Calculation.new(Addr.to_i(router_id), areas, externals, max_paths).run
      end

      # A binary heap of [key, value], smallest key first.
      class Heap
        def initialize
          @a = []
        end

        def empty? = @a.empty?

        def push(key, value)
          @a << [key, value]
          i = @a.size - 1
          while i.positive?
            parent = (i - 1) / 2
            break if (@a.at(parent).first <=> @a.at(i).first) <= 0
            @a[parent], @a[i] = @a.at(i), @a.at(parent)
            i = parent
          end
        end

        def pop
          top = @a.first
          last = @a.pop
          unless @a.empty?
            @a[0] = last
            i = 0
            loop do
              l = 2 * i + 1
              r = l + 1
              m = i
              m = l if l < @a.size && (@a.at(l).first <=> @a.at(m).first).negative?
              m = r if r < @a.size && (@a.at(r).first <=> @a.at(m).first).negative?
              break if m == i
              @a[m], @a[i] = @a.at(i), @a.at(m)
              i = m
            end
          end
          top
        end
      end

      # One run. Vertices are [:router, id] or [:network, ls_id].
      class Calculation
        Vertex = Struct.new(:id, :lsa, :dist, :next_hops, :parents)

        def initialize(root, areas, externals, max_paths)
          @root = root
          @areas = areas
          @externals = externals
          @max_paths = max_paths
          @routes = {}
          @routers = {}
          @stats = { vertices: 0, areas: areas.size, skipped: [] }
          @bodies = {}.compare_by_identity
        end

        def run
          @areas.each { |a| intra_area(a) }
          inter_area
          external
          @routes.each_value { |r| finish(r) }
          @routers.each_value { |r| finish(r) }
          Table.new(routes: @routes, routers: @routers, stats: @stats)
        end

        private

        # ---- 16.1: the shortest-path tree of one area ----

        def intra_area(area)
          db = index(area)
          root_lsa = db.router(@root)
          return unless root_lsa

          tree = {}
          cand = {}
          heap = Heap.new
          v = Vertex.new([:router, @root], root_lsa, 0, [], [])
          loop do
            tree[v.id] = v
            transit_route(area, v) if v.id[0] == :network
            router_entry(area, v) if v.id[0] == :router && v.id[1] != @root
            each_transit_link(db, v) do |w_id, w_lsa, cost, link|
              next if tree.key?(w_id)
              d = v.dist + cost
              c = cand[w_id]
              next if c && d > c.dist
              hops = next_hops(area, v, w_id, w_lsa, link)
              # Our LSA can still list a link whose interface just went
              # down. No way out: not a path (other ways may still be).
              next if hops.empty?
              if c && d == c.dist
                c.next_hops |= hops
                c.parents << v.id
              else
                c = cand[w_id] = Vertex.new(w_id, w_lsa, d, hops, [v.id])
                # Ties: transit networks before routers (16.1 step 3).
                heap.push([d, w_id[0] == :network ? 0 : 1, w_id[1]], w_id)
              end
            end
            v = nil
            until heap.empty?
              key, id = heap.pop
              c = cand[id]
              next unless c && !tree.key?(id) && key[0] == c.dist
              v = cand.delete(id)
              break
            end
            break unless v
          end
          @stats[:vertices] += tree.size
          stub_routes(area, tree)
        end

        # Router-LSAs by router id; network-LSAs by the DR's address (a
        # transit link names only the address, and after a DR change two
        # network-LSAs from different routers may share it for a while).
        Db = Struct.new(:routers, :networks, :links) do
          def router(id) = routers[id]

          def network(dr_address)
            list = networks[dr_address] or return nil
            return list.first if list.size == 1
            # The live one comes from the router that has the address.
            list.find do |n|
              r = routers[n.advr]
              links = (r && self.links.call(r)) || []
              links.any? { |l| l.type == 2 && l.id == dr_address && l.data == dr_address }
            end || list.max_by(&:advr)
          end
        end

        def index(area)
          db = Db.new({}, Hash.new { |h, k| h[k] = [] }, method(:router_links))
          area.lsas.each do |l|
            next if l.max_age?
            case l.type
            when 1 then db.routers[l.advr] = l if l.ls_id == l.advr
            when 2 then db.networks[l.ls_id] << l
            end
          end
          db
        end

        # Yields each vertex W that V links to and that links back to V
        # (the two-way check), with the cost and V's link.
        def each_transit_link(db, v)
          if v.id[0] == :router
            links = router_links(v.lsa) or return
            links.each do |link|
              case link.type
              when 1 # point-to-point
                w = db.router(link.id)
                next unless w && links_back?(w, v.id)
                yield [:router, link.id], w, link.metric, link
              when 2 # transit network; link id is the DR's address
                w = db.network(link.id)
                next unless w && links_back?(w, v.id)
                yield [:network, link.id], w, link.metric, link
              end
            end
          else
            parts = network_body(v.lsa) or return
            _, attached = parts
            attached.uniq.each do |rid|
              w = db.router(rid)
              next unless w && links_back?(w, v.id)
              yield [:router, rid], w, 0, nil
            end
          end
        end

        def links_back?(w_lsa, v_id)
          kind, id = v_id
          if w_lsa.type == 2
            return false unless kind == :router
            parts = network_body(w_lsa) or return false
            _, attached = parts
            attached.include?(id)
          else
            links = router_links(w_lsa) or return false
            if kind == :router
              links.any? { |l| l.type == 1 && l.id == id }
            else
              links.any? { |l| l.type == 2 && l.id == id }
            end
          end
        end

        # ---- 16.1.1: next hops ----

        def next_hops(area, parent, w_id, w_lsa, link)
          if parent.id == [:router, @root]
            iface = area.interfaces.find { |i| i.address == link.data } ||
                    area.interfaces.find { |i| i.on?(link.data) }
            return [] unless iface
            return [NextHop.new(iface.name, nil)] if w_id[0] == :network
            # The neighbor's address: its link back to us on this subnet.
            back = router_links(w_lsa).find { |l| l.type == 1 && l.id == @root && iface.on?(l.data) }
            [NextHop.new(iface.name, back&.data || iface.neighbors[w_id[1]])]
          elsif parent.id[0] == :network && parent.parents.include?([:router, @root])
            # The parent is a network we sit on. Out of the interface we
            # reach it by, the next hop is W's own address on it. Any hops
            # the network also inherited through another router stay.
            direct, via = parent.next_hops.partition { |h| h.gateway.nil? }
            addrs = router_links(w_lsa).select { |l| l.type == 2 && l.id == parent.id[1] }.map(&:data)
            direct.flat_map { |h| addrs.map { |a| NextHop.new(h.interface, a) } } + via
          else
            parent.next_hops.dup
          end
        end

        # ---- routes from the tree ----

        def transit_route(area, v)
          parts = network_body(v.lsa) or return
          mask, = parts
          return skip(v.lsa, 'network-LSA with mask 0.0.0.0') if mask.zero?
          len = prefix_len(mask, v.lsa) or return
          add_intra(area, v.id[1] & mask, len, v.dist, v.next_hops, v.lsa.advr)
        end

        # 16.1 stage 2: stub networks hang off the routers in the tree.
        def stub_routes(area, tree)
          tree.each_value do |v|
            next unless v.id[0] == :router
            links = router_links(v.lsa) or next
            links.each do |l|
              next unless l.type == 3
              len = prefix_len(l.data, v.lsa) or next
              hops = if v.id[1] == @root
                       iface = area.interfaces.find { |i| i.on?(l.id) }
                       iface ? [NextHop.new(iface.name, nil)] : []
                     else
                       v.next_hops
                     end
              add_intra(area, l.id & l.data, len, v.dist + l.metric, hops, v.id[1])
            end
          end
        end

        def add_intra(area, prefix, len, cost, hops, advr)
          key = [prefix, len]
          cur = @routes[key]
          if cur.nil? || cur.path_type != :intra || cost < cur.cost
            @routes[key] = Route.new(prefix: prefix, prefix_len: len, path_type: :intra, cost: cost,
                                     area: area.id, next_hops: hops.dup, advr: advr)
          elsif cost == cur.cost
            cur.next_hops |= hops
          end
        end

        # ABRs and ASBRs reached in this area (16.1 step 4).
        def router_entry(area, v)
          parts = router_body(v.lsa) or return
          flags, = parts
          return if (flags & 0x3).zero? # neither B nor E
          @routers[[v.id[1], area.id]] = Route.new(prefix: v.id[1], prefix_len: 32, path_type: :intra, cost: v.dist,
                                                    area: area.id, next_hops: v.next_hops.dup, advr: v.id[1],
                                                    tag: { abr: (flags & 1) == 1, asbr: (flags & 2) == 2 })
        end

        # ---- 16.2: inter-area routes ----

        def inter_area
          # Active attachments (16.2): an interface up in the area.
          attached = @areas.select { |a| a.interfaces.any? && a.lsas.any? { |l| l.key == [1, @root, @root] } }
          backbone = attached.find { |a| a.id.zero? }
          # An ABR looks at backbone summaries only.
          examined = attached.size > 1 ? [backbone].compact : attached
          examined.each do |area|
            area.lsas.each do |l|
              next unless [3, 4].include?(l.type) && !l.max_age? && l.advr != @root
              next if l.type == 4 && l.ls_id == @root
              parts = summary_body(l) or next
              mask, metric = parts
              next if metric == LS_INFINITY
              br = @routers[[l.advr, area.id]]
              next unless br && br.tag[:abr]
              cost = br.cost + metric
              if l.type == 3
                len = prefix_len(mask, l) or next
                add_inter(@routes, [l.ls_id & mask, len], len, area, cost, br)
              else
                add_inter(@routers, [l.ls_id, area.id], 32, area, cost, br, asbr: true)
              end
            end
          end
        end

        def add_inter(table, key, len, area, cost, br, asbr: false)
          cur = table[key]
          return if cur && cur.path_type == :intra
          if cur.nil? || %i[ext1 ext2].include?(cur.path_type) || cost < cur.cost
            table[key] = Route.new(prefix: key[0], prefix_len: len, path_type: :inter, cost: cost, area: area.id,
                                   next_hops: br.next_hops.dup, advr: br.advr,
                                   tag: asbr ? { abr: false, asbr: true } : nil)
          elsif cost == cur.cost
            cur.next_hops |= br.next_hops
          end
        end

        # ---- 16.4: AS external routes ----

        def external
          index_internal
          own = @areas.flat_map { |a| a.interfaces.map(&:address) }.to_h { |x| [x, true] }
          @asbrs = Hash.new { |h, rid| h[rid] = find_asbr(rid) }
          @externals.each do |l|
            next unless l.type == 5 && !l.max_age? && l.advr != @root
            body = external_body(l) or next
            mask, e_bit, metric, fwd, tag = body
            next if metric == LS_INFINITY
            next if own[fwd] # the ASBR points back at us
            asbr = @asbrs[l.advr] or next
            if fwd.zero?
              base = asbr
              hops = asbr.next_hops
            else
              base = lookup(fwd)
              next unless base && %i[intra inter].include?(base.path_type)
              # A forwarding address on a network we sit on is the next hop.
              hops = base.next_hops.map { |h| h.gateway ? h : NextHop.new(h.interface, fwd) }
            end
            len = prefix_len(mask, l) or next
            route = Route.new(prefix: l.ls_id & mask, prefix_len: len, path_type: e_bit ? :ext2 : :ext1,
                              cost: e_bit ? base.cost : base.cost + metric, type2_cost: e_bit ? metric : nil,
                              area: nil, next_hops: hops.dup, advr: l.advr, tag: tag,
                              forwarding: fwd.zero? ? nil : fwd)
            add_external([route.prefix, len], route)
          end
        end

        def find_asbr(rid)
          @routers.select { |(id, _), r| id == rid && r.tag && r.tag[:asbr] }.values.min_by { |r| [r.cost, -r.area.to_i] }
        end

        def add_external(key, route)
          cur = @routes[key]
          if cur.nil?
            @routes[key] = route
            return
          end
          case compare_external(route, cur)
          when -1 then @routes[key] = route
          when 0 then cur.next_hops |= route.next_hops
          end
        end

        # -1 if +a+ is better than the current route +b+, 0 if as good.
        def compare_external(a, b)
          return 1 if %i[intra inter].include?(b.path_type)
          rank = { ext1: 0, ext2: 1 }
          return rank[a.path_type] <=> rank[b.path_type] unless a.path_type == b.path_type
          return a.cost <=> b.cost if a.path_type == :ext1
          [a.type2_cost, a.cost] <=> [b.type2_cost, b.cost]
        end

        # Intra and inter-area routes by prefix length, for forwarding
        # addresses: externals go in after, so the index stays valid.
        def index_internal
          @internal = Hash.new { |h, k| h[k] = {} }
          @routes.each_value { |r| @internal[r.prefix_len][r.prefix] = r if %i[intra inter].include?(r.path_type) }
          @internal_lens = @internal.keys.sort.reverse
        end

        # Longest-prefix match among the internal routes.
        def lookup(ip)
          @internal_lens.each do |len|
            r = @internal[len][ip & Addr.mask(len)]
            return r if r
          end
          nil
        end

        # ---- helpers ----

        def finish(r)
          r.next_hops = r.next_hops.uniq.sort_by(&:sort_key).first(@max_paths)
        end

        def prefix_len(mask, lsa)
          Addr.prefix_len(mask)
        rescue ArgumentError
          skip(lsa, "mask #{Addr.to_s(mask)} is not contiguous")
        end

        # Bodies are parsed once per run: Dijkstra looks at each LSA from
        # both ends of every link.
        def router_body(lsa)
          @bodies.fetch(lsa) do
            @bodies[lsa] = begin
              lsa.router_body
            rescue Lsa::Error => e
              skip(lsa, e)
            end
          end
        end

        def router_links(lsa)
          router_body(lsa)&.last
        end

        def network_body(lsa)
          @bodies.fetch(lsa) do
            @bodies[lsa] = begin
              lsa.network_body
            rescue Lsa::Error => e
              skip(lsa, e)
            end
          end
        end

        def summary_body(lsa)
          b = lsa.body
          return skip(lsa, 'summary body too short') if b.bytesize < 8
          mask, metric = b.unpack('NN')
          [mask, metric & 0xff_ffff]
        end

        def external_body(lsa)
          b = lsa.body
          return skip(lsa, 'external body too short') if b.bytesize < 16
          mask, m, fwd, tag = b.unpack('NNNN')
          [mask, (m >> 31) == 1, m & 0xff_ffff, fwd, tag]
        end

        def skip(lsa, why)
          @stats[:skipped] << "#{lsa.id_string}: #{why.respond_to?(:message) ? why.message : why}"
          nil
        end
      end
    end
  end
end
