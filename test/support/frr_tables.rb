# frozen_string_literal: true

require 'ospfv2/core'
require 'ospfv2/core/spf'

# FRR's routing table and ours in one shape, to compare them:
#
#   [{ "prefix" => [type, cost, type2, [[interface, gateway], ...]] },
#    { "router id" => [type, cost, [[interface, gateway], ...]] }]
module FrrTables
  include OSPFv2::Core

  FRR_TYPES = { 'N' => 'intra', 'N IA' => 'inter', 'N E1' => 'ext1', 'N E2' => 'ext2' }.freeze

  module_function

  # FRR router +name+'s table, from show ip ospf route json.
  def frr_table(topology, name)
    nets = {}
    routers = {}
    topology.frr_json(name, 'show ip ospf route').each do |dest, r|
      # uniq: FRR lists one next hop twice when two equal paths share it.
      hops = r['nexthops'].map { |h| h['directlyAttachedTo'] ? [h['directlyAttachedTo'], nil] : [h['via'], h['ip']] }.uniq.sort
      if dest.include?('/')
        nets[dest] = [FRR_TYPES.fetch(r['routeType']), r['cost'], r['type2cost'], hops]
      else
        routers[dest] = [r['ia'] ? 'inter' : 'intra', r['cost'], hops]
      end
    end
    [nets, routers]
  end

  def ours(table)
    hops = ->(r) { r.next_hops.map { |h| [h.interface, h.gateway && Addr.to_s(h.gateway)] }.sort }
    nets = table.routes.values.to_h { |r| [r.dest_s, [r.path_type.to_s, r.cost, r.type2_cost, hops[r]]] }
    routers = table.routers.values.to_h { |r| [Addr.to_s(r.prefix), [r.path_type.to_s, r.cost, hops[r]]] }
    [nets, routers]
  end

  # Our SPF from router +root+'s seat (an FRR router in one area), on the
  # databases core router +core+ holds for that area and the AS.
  def rerooted(topology, core, root)
    state = topology.core_state(core)
    lsas = ->(hexes) { hexes.map { |h| Lsa.new([h].pack('H*')) } }
    r = topology.routers.fetch(root)
    area = r.links.map(&:area).uniq
    raise "#{root} is in several areas" unless area.size == 1
    area = area.first
    links = r.links.map { |l| Spf::Link.new(name: l.ifname, address: l.address, prefix_len: l.prefix_len) }
    links << Spf::Link.new(name: 'lo', address: r.router_id, prefix_len: 32) if r.loopback_area == area
    opts = (topology.routers.fetch(core).areas || {})[Addr.to_s(area)] || {}
    db = Spf::Area.new(id: area, lsas: lsas[state.dig('lsas', Addr.to_s(area)) || []], interfaces: links,
                       nssa: !(opts[:nssa] || opts['nssa']).nil?)
    Spf.run(router_id: r.router_id, areas: [db], externals: lsas[state['externals'] || []])
  end

  # A core router's table from its state file, in the shape above.
  def core_routes(topology, core)
    (topology.core_state(core)['routes'] || {}).transform_values do |r|
      [r['path_type'], r['cost'], r['type2_cost'], r['next_hops'].sort]
    end
  end

  def pp_table((nets, routers))
    (nets.sort + routers.sort).map { |k, v| "  #{k} #{v.inspect}" }.join("\n")
  end
end
