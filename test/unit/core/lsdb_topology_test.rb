# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'ospfv2/core/spf'
require 'ospfv2/core/lsdb_topology'

# The LSDB as nodes, links and prefixes (docs/design/ospf-topology.md).
# The topology is routescope's bgp-ls-ospf lab, seen from o2:
#
#   area 0                          area 1
#   o1 .1 --10.0.12.0/30-- .2 o2 .1 --10.0.23.0/24-- .3 o3 --> 192.0.2.0/24 (E2)
#   10.255.0.1        (ABR) 10.255.0.2   o2 is DR   10.255.0.3 (ASBR)
class TestLsdbTopology < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  A = ->(s) { Addr.to_i(s) }
  O1 = '10.255.0.1'
  O2 = '10.255.0.2'
  O3 = '10.255.0.3'

  def rtr(id, links, flags: 0, age: 0)
    Lsa.router(advr: id, seq: 1, flags: flags, age: age, links: links.map do |type, lid, data, metric|
      { type: { p2p: 1, transit: 2, stub: 3, virtual: 4 }.fetch(type), id: lid, data: data, metric: metric }
    end)
  end

  def net(dr_address, advr, len, attached, age: 0)
    Lsa.network(dr_address: dr_address, advr: advr, mask: Addr.mask(len), attached: attached, seq: 1, age: age)
  end

  def summary(prefix, len, advr, metric, type: 3)
    Lsa.build(type: type, ls_id: prefix, advr: advr, seq: 1, body: [type == 4 ? 0 : Addr.mask(len), metric].pack('NN'))
  end

  def ext(prefix, len, advr, metric, type: 5, e2: true, fwd: '0.0.0.0', tag: 0, age: 0)
    Lsa.build(type: type, ls_id: prefix, advr: advr, seq: 1, age: age,
              body: [Addr.mask(len), (e2 ? 0x8000_0000 : 0) | metric, A[fwd], tag].pack('NNNN'))
  end

  def loopback(id) = [:stub, id, '255.255.255.255', 0]

  def area0
    [rtr(O1, [[:p2p, O2, '10.0.12.1', 10], [:stub, '10.0.12.0', '255.255.255.252', 10], loopback(O1)]),
     rtr(O2, [[:p2p, O1, '10.0.12.2', 10], [:stub, '10.0.12.0', '255.255.255.252', 10], loopback(O2),
              [:virtual, '10.255.0.9', '10.0.12.2', 5]], flags: 1),
     summary('10.0.23.0', 24, O2, 10),
     summary(O3, 32, O2, 10, type: 4)]
  end

  def area1
    [rtr(O2, [[:transit, '10.0.23.1', '10.0.23.1', 10]], flags: 1),
     rtr(O3, [[:transit, '10.0.23.1', '10.0.23.3', 10], loopback(O3)], flags: 2),
     net('10.0.23.1', O2, 24, [O2, O3]),
     summary('10.0.12.0', 30, O2, 10),
     summary(O1, 32, O2, 10)]
  end

  def spf(lsas, area)
    Spf.run(router_id: O2, areas: [Spf::Area.new(id: area, lsas: lsas,
                                                 interfaces: [Spf::Link.new(name: 'eth1', address: '10.0.12.2', prefix_len: 30),
                                                              Spf::Link.new(name: 'eth2', address: '10.0.23.1', prefix_len: 24)])])
  end

  def topo(lsas, area = 0) = LsdbTopology.area(lsas, reached: spf(lsas, area).reached[area])
  def node(nodes, id) = nodes.find { |n| n[:id] == id }

  def test_p2p_links_have_both_addresses_when_two_way
    nodes = topo(area0)
    o1 = node(nodes, O1)
    assert_equal({ id: O1, kind: 'router', reachable: true, abr: false, asbr: false,
                   neighbors: [{ id: O2, type: 'p2p', metric: 10, address: '10.0.12.1', remote_address: '10.0.12.2' }],
                   prefixes: [{ prefix: '10.0.12.0/30', metric: 10, route_type: 'intra' },
                              { prefix: '10.255.0.1/32', metric: 0, route_type: 'intra' }] }, o1)
  end

  def test_one_way_p2p_has_no_remote_address_and_virtual_links_are_left_out
    lsas = area0
    lsas[0] = rtr(O1, [[:p2p, O2, '10.0.12.1', 10], [:p2p, '10.255.0.5', '10.0.15.1', 7]])
    nodes = topo(lsas)
    n = node(nodes, O1)[:neighbors]
    assert_equal({ id: '10.255.0.5', type: 'p2p', metric: 7, address: '10.0.15.1' }, n[1])
    o2 = node(nodes, O2)
    assert_equal [O1], o2[:neighbors].map { _1[:id] }, 'no virtual link'
    assert o2[:abr]
  end

  def test_an_abr_has_its_type_3_summaries_as_inter_and_no_type_4
    o2 = node(topo(area0), O2)
    assert_equal [['10.0.12.0/30', 'intra'], ['10.0.23.0/24', 'inter'], ['10.255.0.2/32', 'intra']],
                 o2[:prefixes].map { [_1[:prefix], _1[:route_type]] }
    refute(o2[:prefixes].any? { _1[:prefix].start_with?(O3) }, 'a type 4 is not a prefix')
  end

  def test_a_lan_is_a_network_node_named_dr_and_address
    nodes = topo(area1, 1)
    assert_equal [O2, O3, "#{O2}:10.0.23.1"], nodes.map { _1[:id] }
    lan = node(nodes, "#{O2}:10.0.23.1")
    assert_equal({ id: "#{O2}:10.0.23.1", kind: 'network', reachable: true, dr: O2, address: '10.0.23.1',
                   neighbors: [{ id: O2, metric: 0 }, { id: O3, metric: 0 }],
                   prefixes: [{ prefix: '10.0.23.0/24', metric: 0, route_type: 'intra' }] }, lan)
    o3 = node(nodes, O3)
    assert_equal [{ id: "#{O2}:10.0.23.1", type: 'transit', metric: 10 }], o3[:neighbors]
    assert o3[:asbr]
    assert_equal ['10.255.0.3/32'], o3[:prefixes].map { _1[:prefix] }, "o2's summaries are o2's"
  end

  def test_a_router_spf_did_not_reach
    lsas = area1 + [rtr('10.255.0.9', [[:transit, '10.0.23.1', '10.0.23.9', 10]])] # not in the network-LSA
    nodes = topo(lsas, 1)
    refute node(nodes, '10.255.0.9')[:reachable]
    assert node(nodes, O3)[:reachable]
    assert(LsdbTopology.area(lsas).none? { _1[:reachable] }, 'no tree: nothing reached')
  end

  def test_a_stale_network_lsa_and_max_age_lsas
    lsas = area1 + [net('10.0.23.1', '10.255.0.7', 24, ['10.255.0.7', O2]),
                    rtr('10.255.0.8', [loopback('10.255.0.8')], age: OSPFv2::MaxAge)]
    nodes = topo(lsas, 1)
    assert_equal [true, false], %W[#{O2}:10.0.23.1 10.255.0.7:10.0.23.1].map { node(nodes, _1)[:reachable] }
    assert_equal "#{O2}:10.0.23.1", node(nodes, O3)[:neighbors][0][:id], 'the live one, as SPF picks'
    assert_nil node(nodes, '10.255.0.8')
  end

  def test_parallel_p2p_links_pair_by_subnet
    lsas = [rtr(O1, [[:p2p, O2, '10.0.12.1', 10], [:stub, '10.0.12.0', '255.255.255.252', 10],
                     [:p2p, O2, '10.0.21.1', 20], [:stub, '10.0.21.0', '255.255.255.252', 20]]),
            rtr(O2, [[:p2p, O1, '10.0.21.2', 20], [:stub, '10.0.21.0', '255.255.255.252', 20],
                     [:p2p, O1, '10.0.12.2', 10], [:stub, '10.0.12.0', '255.255.255.252', 10]])]
    n = node(topo(lsas), O1)[:neighbors]
    assert_equal [%w[10.0.12.1 10.0.12.2], %w[10.0.21.1 10.0.21.2]], n.map { [_1[:address], _1[:remote_address]] }
  end

  def test_bad_bodies_and_masks_are_left_out
    lsas = area0 + [rtr('10.255.0.6', [[:stub, '10.6.0.0', '255.0.255.0', 1]]),
                    Lsa.build(type: 1, ls_id: '10.255.0.7', advr: '10.255.0.7', seq: 1, body: "\x00")]
    nodes = topo(lsas)
    assert_equal [], node(nodes, '10.255.0.6')[:prefixes]
    assert_nil node(nodes, '10.255.0.7')
  end

  def test_type_7_lsas_of_a_router_in_an_nssa
    lsas = [rtr(O3, [loopback(O3)], flags: 2), ext('198.51.100.0', 24, O3, 30, type: 7, e2: false, fwd: '10.0.23.3', tag: 7)]
    o3 = node(LsdbTopology.area(lsas), O3)
    assert_equal({ prefix: '198.51.100.0/24', metric: 30, route_type: 'nssa_1', forwarding: '10.0.23.3', tag: 7 },
                 o3[:prefixes][1])
  end

  def test_the_as_scope_by_asbr
    lsas = [ext('192.0.2.0', 24, O3, 20), ext('198.51.100.0', 24, O3, 5, e2: false, fwd: '10.0.23.3', tag: 42),
            ext('203.0.113.0', 24, '10.255.0.9', 1), ext('203.0.114.0', 24, O3, 1, age: OSPFv2::MaxAge),
            summary('10.9.0.0', 16, O3, 1)]
    nodes = LsdbTopology.as(lsas, reachable: ->(rid) { rid == A[O3] })
    assert_equal [
      { id: O3, kind: 'router', reachable: true,
        prefixes: [{ prefix: '192.0.2.0/24', metric: 20, route_type: 'external_2', forwarding: '0.0.0.0', tag: 0 },
                   { prefix: '198.51.100.0/24', metric: 5, route_type: 'external_1', forwarding: '10.0.23.3', tag: 42 }] },
      { id: '10.255.0.9', kind: 'router', reachable: false,
        prefixes: [{ prefix: '203.0.113.0/24', metric: 1, route_type: 'external_2', forwarding: '0.0.0.0', tag: 0 }] }
    ], nodes
  end
end
