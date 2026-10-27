# frozen_string_literal: true

require 'test/unit'
require 'support/frr_topology'
require 'ospfv2/core/spf'

# Our routing table against FRR's, on one database. Opt in with
# OSPFV2_FRR=1 as root with FRR installed:
#
#   sudo OSPFV2_FRR=1 ruby -Ilib -Itest test/integration/frr_spf_test.rb
#
#   r1 (core) --LAN-- r2 (FRR) ==two p2p links== r3 (FRR, ABR) --LAN, area 1-- r4 (FRR, ASBR)
#                                                                              192.0.2.0/24 E2 20
#                                                                              198.51.100.0/24 E1 5
#
# Two checks, each time the network changes:
# * SPF rooted at r2 over the database r1 learned must give exactly FRR
#   r2's table: same routes, types, costs and next hops (ECMP included).
# * r1's own table must be r2's, one LAN hop further: every cost 10 more,
#   every next hop r2.
class TestFrrSpf < Test::Unit::TestCase
  include OSPFv2::Core

  EXT = ['route-map EXT permit 10', ' match interface ext1', ' set metric 20', ' set metric-type type-2',
         'route-map EXT permit 20', ' match interface ext2', ' set metric 5', ' set metric-type type-1'].freeze

  FRR_TYPES = { 'N' => 'intra', 'N IA' => 'inter', 'N E1' => 'ext1', 'N E2' => 'ext2' }.freeze

  def setup
    ok, why = FrrLab.available?
    omit(why) unless ok
    @t = FrrTopology.new("spf#{Process.pid % 1000}")
    @t.core('r1', '1.1.1.1')
    @t.frr('r2', '2.2.2.2')
    @t.frr('r3', '3.3.3.3')
    @t.frr('r4', '4.4.4.4', loopback_area: 1, frr_extra: EXT, extra: ['redistribute connected route-map EXT'],
                            dummies: { 'ext1' => '192.0.2.1/24', 'ext2' => '198.51.100.1/24' })
    @t.link('r1', 'r2', '10.0.12.0/24')
    @t.link('r2', 'r3', '10.0.23.0/30', p2p: true)
    @t.link('r2', 'r3', '10.0.23.4/30', p2p: true)
    @t.link('r3', 'r4', '10.0.34.0/24', area: 1)
    @t.start
  end

  def teardown
    @t&.stop
  end

  # ---- FRR's table, and ours, in one shape ----
  # { "prefix" => [type, cost, type2, [[interface, gateway], ...]] } and
  # { "router id" => [type, cost, [[interface, gateway], ...]] }

  def frr_table
    json = @t.frr_json('r2', 'show ip ospf route')
    nets = {}
    routers = {}
    json.each do |dest, r|
      hops = r['nexthops'].map { |h| h['directlyAttachedTo'] ? [h['directlyAttachedTo'], nil] : [h['via'], h['ip']] }.sort
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

  # SPF from r2's seat, on what r1 holds.
  def rerooted
    state = @t.core_state('r1')
    lsas = ->(hexes) { hexes.map { |h| Lsa.new([h].pack('H*')) } }
    r2 = @t.routers['r2']
    links = r2.links.select { |l| l.area.zero? }.map { |l| Spf::Link.new(name: l.ifname, address: l.address, prefix_len: l.prefix_len) }
    links << Spf::Link.new(name: 'lo', address: r2.router_id, prefix_len: 32)
    area0 = Spf::Area.new(id: 0, lsas: lsas[state.dig('lsas', '0.0.0.0') || []], interfaces: links)
    Spf.run(router_id: r2.router_id, areas: [area0], externals: lsas[state['externals'] || []])
  end

  # r1's table as JSON from its state file, in the shape above.
  def core_routes
    (@t.core_state('r1')['routes'] || {}).transform_values do |r|
      [r['path_type'], r['cost'], r['type2_cost'], r['next_hops'].sort]
    end
  end

  # r2's routes seen from r1: one LAN hop (cost 10) further, through r2.
  def expected_core_routes(frr_nets)
    via_r2 = [['r2a', '10.0.12.2']]
    out = frr_nets.to_h do |dest, (type, cost, type2, _)|
      [dest, [type, cost + 10, type2, via_r2]]
    end
    out['10.0.12.0/24'] = ['intra', 10, nil, [['r2a', nil]]]
    out['1.1.1.1/32'] = ['intra', 10, nil, [['lo', nil]]]
    out
  end

  def assert_tables_agree(must_have)
    last = nil
    ok = @t.wait_for(90) do
      frr = frr_table
      mine = ours(rerooted)
      core = core_routes
      last = [frr, mine, core]
      must_have.all? { |p| frr[0].key?(p) } && frr == mine && core == expected_core_routes(frr[0])
    end
    frr, mine, core = last
    assert ok, "FRR r2:\n#{pp_table(frr)}\nours rooted at r2:\n#{pp_table(mine)}\n" \
               "r1:\n#{core.sort.map { |k, v| "  #{k} #{v.inspect}" }.join("\n")}\n" \
               "#{@t.core_log('r1').lines.last(15).join}"
  end

  def pp_table((nets, routers))
    (nets.sort + routers.sort).map { |k, v| "  #{k} #{v.inspect}" }.join("\n")
  end

  def test_routes_match_frr_as_the_network_changes
    all = %w[3.3.3.3/32 4.4.4.4/32 10.0.34.0/24 192.0.2.0/24 198.51.100.0/24]
    assert_tables_agree(all)
    nets, routers = frr_table
    assert_equal 2, nets['4.4.4.4/32'][3].size, 'ECMP over both r2-r3 links'
    assert_equal %w[ext1 ext2 inter intra], nets.values.map(&:first).uniq.sort, 'every path type is covered'
    assert_equal 'inter', routers['4.4.4.4'][0], 'the ASBR is reached through a type 4 summary'

    # One r2-r3 link gets expensive: ECMP collapses onto the other.
    system('vtysh', '-N', @t.pathspace('r2'), '-c', 'configure terminal', '-c', 'interface r3a', '-c', 'ip ospf cost 50',
           out: File::NULL, err: File::NULL)
    @t.wait_for(30) { frr_table[0].dig('4.4.4.4/32', 3)&.size == 1 }
    assert_tables_agree(all)
    assert_equal [['r3b', '10.0.23.6']], frr_table[0]['4.4.4.4/32'][3]

    # An external network goes away.
    system('ip', '-n', @t.ns('r4'), 'link', 'set', 'ext1', 'down')
    @t.wait_for(30) { !frr_table[0].key?('192.0.2.0/24') }
    assert_tables_agree(all - ['192.0.2.0/24'])
    refute core_routes.key?('192.0.2.0/24')
  end
end
