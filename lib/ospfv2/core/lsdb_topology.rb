# frozen_string_literal: true

require 'set'
require_relative 'addr'
require_relative 'lsa'

module OSPFv2
  module Core
    # A link state database read as a graph of nodes, for a BGP-LS
    # Producer (RFC 9552) and for people. A pure function: LSAs and what
    # SPF reached in, plain data out (docs/design/ospf-topology.md).
    #
    #   LsdbTopology.area(lsas, reached: table.reached[area_id])
    #   # => [{ id: '1.1.1.1', kind: 'router', reachable: true, abr:, asbr:,
    #   #       neighbors: [...], prefixes: [...] }, { id: '2.2.2.2:10.0.0.2', kind: 'network', ... }]
    #   LsdbTopology.as(lsas, reachable: ->(asbr) { ... })
    #
    # LSAs at MaxAge are left out. A body that does not decode leaves its
    # node out, as SPF skips it.
    module LsdbTopology
      module_function

      ROUTE_TYPES = { 3 => 'inter', 5 => %w[external_1 external_2], 7 => %w[nssa_1 nssa_2] }.freeze

      # The nodes of one area. +reached+: { routers:, networks: } from
      # Spf::Table#reached, or nil when SPF built no tree there.
      def area(lsas, reached: nil)
        live = lsas.reject(&:max_age?)
        routers = live.select { |l| l.type == 1 && l.ls_id == l.advr }.to_h { |l| [l.advr, l] }
        networks = live.select { |l| l.type == 2 }.group_by(&:ls_id)
        own = live.select { |l| [3, 7].include?(l.type) }.group_by(&:advr)
        r_reached = Set.new(reached&.fetch(:routers, nil) || [])
        n_reached = Set.new(reached&.fetch(:networks, nil) || [])

        router_nodes = routers.keys.sort.filter_map do |id|
          router_node(routers[id], routers, networks, own.fetch(id, []), r_reached.include?(id))
        end
        network_nodes = networks.keys.sort.flat_map do |ls_id|
          live_one = network_for(ls_id, networks, routers)
          networks[ls_id].sort_by(&:advr).filter_map do |n|
            network_node(n, n_reached.include?(ls_id) && n.equal?(live_one))
          end
        end
        router_nodes + network_nodes
      end

      # The AS-scoped LSAs (type 5), by the ASBR that sent them.
      # +reachable+: called with an ASBR's router id (Integer).
      def as(lsas, reachable:)
        live = lsas.reject(&:max_age?).select { |l| l.type == 5 }
        live.group_by(&:advr).sort.map do |advr, list|
          { id: Addr.to_s(advr), kind: 'router', reachable: reachable.call(advr) == true,
            prefixes: sorted(list.filter_map { |l| summary_prefix(l) }) }
        end
      end

      def router_node(lsa, routers, networks, own, reachable)
        flags, links = lsa.router_body
        { id: Addr.to_s(lsa.advr), kind: 'router', reachable: reachable,
          abr: flags[0] == 1, asbr: flags[1] == 1,
          neighbors: neighbors(lsa, links, routers, networks),
          prefixes: sorted(stub_prefixes(links) + own.filter_map { |l| summary_prefix(l) }) }
      rescue Lsa::Error
        nil
      end

      def network_node(lsa, reachable)
        mask, attached = lsa.network_body
        len = Addr.prefix_len(mask)
        { id: network_id(lsa), kind: 'network', reachable: reachable,
          dr: Addr.to_s(lsa.advr), address: Addr.to_s(lsa.ls_id),
          # "arcs leading from networks to routers always have cost 0"
          # (RFC 2328 section 2.1)
          neighbors: attached.uniq.map { |r| { id: Addr.to_s(r), metric: 0 } },
          prefixes: [{ prefix: "#{Addr.to_s(lsa.ls_id & mask)}/#{len}", metric: 0, route_type: 'intra' }] }
      rescue Lsa::Error, ArgumentError
        nil
      end

      # A network node is named as RFC 9552 5.2.1.4 builds an OSPF
      # pseudonode: the DR's Router-ID, then its interface address.
      def network_id(lsa) = "#{Addr.to_s(lsa.advr)}:#{Addr.to_s(lsa.ls_id)}"

      # One per p2p link and one per transit link with a network-LSA.
      # Virtual links are left out (RFC 9552 5.7).
      def neighbors(lsa, links, routers, networks)
        backs = Hash.new { |h, k| h[k] = back_links(routers[k], lsa.advr) }
        seen = Hash.new(0)
        links.filter_map do |l|
          case l.type
          when 1
            n = { id: Addr.to_s(l.id), type: 'p2p', metric: l.metric, address: Addr.to_s(l.data) }
            back = pair(l, seen[l.id], backs[l.id], lsa, routers[l.id])
            seen[l.id] += 1
            back ? n.merge(remote_address: Addr.to_s(back.data)) : n
          when 2
            net = network_for(l.id, networks, routers) or next
            { id: network_id(net), type: 'transit', metric: l.metric }
          end
        end
      end

      # The neighbor's p2p links back to +rid+, in their order.
      def back_links(lsa, rid)
        return [] unless lsa
        lsa.router_links.select { |b| b.type == 1 && b.id == rid }
      rescue Lsa::Error
        []
      end

      # Which of the neighbor's links back is the other end of +link+, the
      # +index+th of ours to that neighbor. Of parallel links, the one on
      # the same subnet, as a stub link of either end says; else by order.
      def pair(link, index, backs, lsa, peer)
        return backs.first if backs.size <= 1
        stubs = (subnets(lsa) + subnets(peer))
        same = backs.find { |b| stubs.any? { |net, mask| (link.data & mask) == net && (b.data & mask) == net } }
        same || backs[index]
      end

      def subnets(lsa)
        return [] unless lsa
        lsa.router_links.select { |s| s.type == 3 && s.data != 0xffff_ffff }.map { |s| [s.id & s.data, s.data] }
      rescue Lsa::Error
        []
      end

      # Of network-LSAs sharing a DR address (after a DR change), the one
      # whose advertising router has that address: what SPF uses.
      def network_for(ls_id, networks, routers)
        list = networks[ls_id] or return nil
        return list.first if list.size == 1
        list.find do |n|
          r = routers[n.advr]
          r && back_links_any?(r, ls_id)
        end || list.max_by(&:advr)
      end

      def back_links_any?(r, ls_id)
        r.router_links.any? { |l| l.type == 2 && l.id == ls_id && l.data == ls_id }
      rescue Lsa::Error
        false
      end

      def stub_prefixes(links)
        links.filter_map do |l|
          next unless l.type == 3
          len = Addr.prefix_len(l.data)
          { prefix: "#{Addr.to_s(l.id & l.data)}/#{len}", metric: l.metric, route_type: 'intra' }
        rescue ArgumentError
          nil
        end
      end

      # A type 3, 5 or 7 LSA as a prefix. Type 4 is not a prefix
      # (RFC 9552 5.8).
      def summary_prefix(lsa)
        d = lsa.detail
        return nil if d[:error] || d[:mask].nil?
        mask = Addr.to_i(d[:mask])
        len = Addr.prefix_len(mask)
        type = ROUTE_TYPES.fetch(lsa.type)
        p = { prefix: "#{Addr.to_s(lsa.ls_id & mask)}/#{len}", metric: d[:metric],
              route_type: type.is_a?(Array) ? type[d.fetch(:external_type, 1) - 1] : type }
        lsa.type == 3 ? p : p.merge(forwarding: d[:forwarding], tag: d[:tag])
      rescue ArgumentError
        nil
      end

      def sorted(prefixes)
        prefixes.sort_by { |p| a, l = p[:prefix].split('/'); [Addr.to_i(a), l.to_i, p[:route_type]] }
      end
    end
  end
end
