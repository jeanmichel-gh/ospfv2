# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'ospfv2/core/spf'

# Golden tests for the routing table calculation (RFC 2328 16).
# Every topology is drawn above its test; R1 is the calculating router.
class TestCoreSpf < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  A = ->(s) { Addr.to_i(s) }

  # -- LSA builders --

  def rtr(id, links, flags: 0, age: 0)
    Lsa.router(advr: id, seq: 1, flags: flags, age: age, links: links.map do |type, lid, data, metric|
      { type: { p2p: 1, transit: 2, stub: 3 }.fetch(type), id: lid, data: data, metric: metric }
    end)
  end

  def net(dr_address, advr, len, attached)
    Lsa.network(dr_address: dr_address, advr: advr, mask: Addr.mask(len), attached: attached, seq: 1)
  end

  def summary(prefix, len, advr, metric, type: 3, age: 0)
    Lsa.build(type: type, ls_id: prefix, advr: advr, seq: 1, age: age,
              body: [type == 4 ? 0 : Addr.mask(len), metric].pack('NN'))
  end

  def external(prefix, len, advr, metric, e2: true, fwd: '0.0.0.0', tag: 0)
    Lsa.build(type: 5, ls_id: prefix, advr: advr, seq: 1,
              body: [Addr.mask(len), (e2 ? 0x8000_0000 : 0) | metric, A[fwd], tag].pack('NNNN'))
  end

  # p2p pair: a's link to b on subnet 10.<a><b>.0.0/30, a gets .1 and b .2
  def p2p(a, b, metric = 10, ai: 1, bi: 2)
    lo, hi = [a, b].minmax
    subnet = "10.#{lo}.#{hi}"
    mine = a == lo ? "#{subnet}.#{ai}" : "#{subnet}.#{bi}"
    [[:p2p, "#{b}.#{b}.#{b}.#{b}", mine, metric], [:stub, "#{subnet}.0", '255.255.255.252', metric]]
  end

  def iface(name, a, b)
    lo, hi = [a, b].minmax
    Spf::Link.new(name: name, address: "10.#{lo}.#{hi}.#{a == lo ? 1 : 2}", prefix_len: 30)
  end

  def spf(lsas, interfaces, router_id: '1.1.1.1', externals: [], area: 0, **opts)
    Spf.run(router_id: router_id, areas: [Spf::Area.new(id: area, lsas: lsas, interfaces: interfaces)],
            externals: externals, **opts)
  end

  def route(table, prefix)
    p, len = prefix.split('/')
    table.routes[[A[p], len.to_i]]
  end

  def hops(r) = r.next_hops.map(&:to_s)

  def loopback(n) = [:stub, "#{n}.#{n}.#{n}.#{n}", '255.255.255.255', 0]

  # R1 --10-- R2 --10-- R4
  #  \--10-- R3 --10--/
  def square
    [
      rtr('1.1.1.1', p2p(1, 2) + p2p(1, 3) + [loopback(1)]),
      rtr('2.2.2.2', p2p(2, 1) + p2p(2, 4) + [loopback(2)]),
      rtr('3.3.3.3', p2p(3, 1) + p2p(3, 4) + [loopback(3)]),
      rtr('4.4.4.4', p2p(4, 2) + p2p(4, 3) + [loopback(4)])
    ]
  end

  def square_ifaces = [iface('eth1', 1, 2), iface('eth2', 1, 3)]

  def test_equal_cost_paths_are_merged
    t = spf(square, square_ifaces)
    r = route(t, '4.4.4.4/32')
    assert_equal :intra, r.path_type
    assert_equal 20, r.cost
    assert_equal ['via 10.1.2.2 eth1', 'via 10.1.3.2 eth2'], hops(r)
    assert_equal ['via 10.1.2.2 eth1'], hops(route(t, '2.2.2.2/32'))
    assert_equal 10, route(t, '2.2.2.2/32').cost
    assert_equal [['via 10.1.2.2 eth1'], 20], [hops(route(t, '10.2.4.0/30')), route(t, '10.2.4.0/30').cost]
  end

  def test_our_own_networks_are_direct
    t = spf(square, square_ifaces)
    assert_equal ['direct eth1'], hops(route(t, '10.1.2.0/30'))
    assert_equal 10, route(t, '10.1.2.0/30').cost
    assert_equal [], hops(route(t, '1.1.1.1/32')), 'a loopback not run as an OSPF interface has no next hop'
    assert_equal 0, route(t, '1.1.1.1/32').cost
  end

  def test_the_cheaper_path_wins_and_max_paths_caps_the_rest
    lsas = square
    lsas[0] = rtr('1.1.1.1', p2p(1, 2, 5) + p2p(1, 3) + [loopback(1)])
    assert_equal ['via 10.1.2.2 eth1'], hops(route(spf(lsas, square_ifaces), '4.4.4.4/32'))
    assert_equal 1, route(spf(square, square_ifaces, max_paths: 1), '4.4.4.4/32').next_hops.size
  end

  def test_a_link_must_be_seen_both_ways
    lsas = square
    lsas[3] = rtr('4.4.4.4', p2p(4, 2) + [loopback(4)]) # R4 no longer lists R3
    t = spf(lsas, square_ifaces)
    assert_equal ['via 10.1.2.2 eth1'], hops(route(t, '4.4.4.4/32'))
    lsas[1] = rtr('2.2.2.2', p2p(2, 1) + [loopback(2)]) # nor does R2 list R4
    assert_nil route(spf(lsas, square_ifaces), '4.4.4.4/32')
  end

  def test_max_age_lsas_are_not_used
    lsas = square
    lsas[1] = rtr('2.2.2.2', p2p(2, 1) + p2p(2, 4) + [loopback(2)], age: OSPFv2::MaxAge)
    t = spf(lsas, square_ifaces)
    assert_nil route(t, '2.2.2.2/32')
    assert_equal ['via 10.1.3.2 eth2'], hops(route(t, '4.4.4.4/32'))
  end

  def test_no_router_lsa_of_our_own_means_no_routes
    assert_empty spf(square[1..], square_ifaces).routes
  end

  def test_parallel_links_to_one_neighbor
    lsas = [
      rtr('1.1.1.1', p2p(1, 2) + p2p(1, 2, ai: 5, bi: 6).map { |l| l[0] == :stub ? [:stub, '10.1.2.4', l[2], l[3]] : l }),
      rtr('2.2.2.2', p2p(2, 1) + p2p(2, 1, ai: 5, bi: 6).map { |l| l[0] == :stub ? [:stub, '10.1.2.4', l[2], l[3]] : l } + [loopback(2)])
    ]
    ifaces = [iface('eth1', 1, 2), Spf::Link.new(name: 'eth2', address: '10.1.2.5', prefix_len: 30)]
    assert_equal ['via 10.1.2.2 eth1', 'via 10.1.2.6 eth2'], hops(route(spf(lsas, ifaces), '2.2.2.2/32'))
  end

  def test_unnumbered_p2p_falls_back_to_the_neighbor_table
    lsas = [
      rtr('1.1.1.1', [[:p2p, '2.2.2.2', '0.0.0.7', 10]]),
      rtr('2.2.2.2', [[:p2p, '1.1.1.1', '0.0.0.3', 10], loopback(2)])
    ]
    ifaces = [Spf::Link.new(name: 'eth7', address: '0.0.0.7', prefix_len: 32, neighbors: { '2.2.2.2' => '192.0.2.2' })]
    assert_equal ['via 192.0.2.2 eth7'], hops(route(spf(lsas, ifaces), '2.2.2.2/32'))
  end

  #   R1 .1   R2 .2 (DR)   R3 .3
  #   |-------10.0.0.0/24------|          R3 --- 33.0.0.0/24 (stub, 1)
  def lan(metric3: 10)
    [
      rtr('1.1.1.1', [[:transit, '10.0.0.2', '10.0.0.1', 10]]),
      rtr('2.2.2.2', [[:transit, '10.0.0.2', '10.0.0.2', 10], loopback(2)]),
      rtr('3.3.3.3', [[:transit, '10.0.0.2', '10.0.0.3', metric3], [:stub, '33.0.0.0', '255.255.255.0', 1]]),
      net('10.0.0.2', '2.2.2.2', 24, %w[2.2.2.2 1.1.1.1 3.3.3.3])
    ]
  end

  def lan_ifaces = [Spf::Link.new(name: 'eth0', address: '10.0.0.1', prefix_len: 24)]

  def test_routers_on_a_lan_are_reached_directly_not_via_the_dr
    t = spf(lan, lan_ifaces)
    assert_equal ['direct eth0'], hops(route(t, '10.0.0.0/24'))
    assert_equal 10, route(t, '10.0.0.0/24').cost
    r = route(t, '33.0.0.0/24')
    assert_equal ['via 10.0.0.3 eth0'], hops(r)
    assert_equal 11, r.cost, 'the network to router hop costs nothing'
    assert_equal ['via 10.0.0.2 eth0'], hops(route(t, '2.2.2.2/32'))
  end

  def test_a_router_not_in_the_network_lsa_is_not_reached
    lsas = lan
    lsas[3] = net('10.0.0.2', '2.2.2.2', 24, %w[2.2.2.2 1.1.1.1])
    assert_nil route(spf(lsas, lan_ifaces), '33.0.0.0/24')
  end

  def test_a_stale_network_lsa_from_an_old_dr_is_ignored
    lsas = lan + [net('10.0.0.2', '9.9.9.9', 24, %w[9.9.9.9 1.1.1.1])]
    assert_equal ['via 10.0.0.3 eth0'], hops(route(spf(lsas, lan_ifaces), '33.0.0.0/24'))
  end

  # R1 is on the LAN and also has a p2p link to R3; both cost 11 to 33/24.
  def test_lan_and_p2p_paths_of_equal_cost_merge
    lsas = lan
    lsas[0] = rtr('1.1.1.1', [[:transit, '10.0.0.2', '10.0.0.1', 10]] + p2p(1, 3, 10))
    lsas[2] = rtr('3.3.3.3', [[:transit, '10.0.0.2', '10.0.0.3', 10], [:stub, '33.0.0.0', '255.255.255.0', 1]] + p2p(3, 1, 10))
    ifaces = lan_ifaces + [iface('eth3', 1, 3)]
    assert_equal ['via 10.0.0.3 eth0', 'via 10.1.3.2 eth3'], hops(route(spf(lsas, ifaces), '33.0.0.0/24'))
  end

  # R1 reaches the LAN directly (10) and through R3 (5 + 5): R4 behind the
  # LAN keeps both ways.
  def test_a_lan_reached_two_ways_keeps_both_next_hops
    lsas = lan
    lsas[0] = rtr('1.1.1.1', [[:transit, '10.0.0.2', '10.0.0.1', 10]] + p2p(1, 3, 5))
    lsas[2] = rtr('3.3.3.3', [[:transit, '10.0.0.2', '10.0.0.3', 5]] + p2p(3, 1, 5))
    lsas << rtr('4.4.4.4', [[:transit, '10.0.0.2', '10.0.0.4', 10], loopback(4)])
    lsas[3] = net('10.0.0.2', '2.2.2.2', 24, %w[2.2.2.2 1.1.1.1 3.3.3.3 4.4.4.4])
    t = spf(lsas, lan_ifaces + [iface('eth3', 1, 3)])
    assert_equal ['direct eth0', 'via 10.1.3.2 eth3'], hops(route(t, '10.0.0.0/24'))
    assert_equal ['via 10.0.0.4 eth0', 'via 10.1.3.2 eth3'], hops(route(t, '4.4.4.4/32'))
    assert_equal 10, route(t, '4.4.4.4/32').cost
  end

  # area 1: R1 --10-- R2 (ABR) ; R2 summarises 172.16.0.0/16 metric 5
  def inter(more = [])
    [
      rtr('1.1.1.1', p2p(1, 2)),
      rtr('2.2.2.2', p2p(2, 1) + [loopback(2)], flags: 1),
      summary('172.16.0.0', 16, '2.2.2.2', 5)
    ] + more
  end

  def test_inter_area_routes_through_an_abr
    t = spf(inter, [iface('eth1', 1, 2)], area: 1)
    r = route(t, '172.16.0.0/16')
    assert_equal :inter, r.path_type
    assert_equal 15, r.cost
    assert_equal A['0.0.0.1'], r.area
    assert_equal ['via 10.1.2.2 eth1'], hops(r)
    assert t.routers[[A['2.2.2.2'], A['0.0.0.1']]].tag[:abr]
  end

  def test_summaries_that_must_be_ignored
    more = [
      summary('172.17.0.0', 16, '2.2.2.2', Spf::LS_INFINITY),
      summary('172.18.0.0', 16, '2.2.2.2', 1, age: OSPFv2::MaxAge),
      summary('172.19.0.0', 16, '1.1.1.1', 1),             # our own
      summary('172.20.0.0', 16, '9.9.9.9', 1),             # unreachable ABR
      summary('2.2.2.2', 32, '2.2.2.2', 1)                 # an intra-area route is better
    ]
    t = spf(inter(more), [iface('eth1', 1, 2)], area: 1)
    %w[172.17.0.0/16 172.18.0.0/16 172.19.0.0/16 172.20.0.0/16].each { |p| assert_nil route(t, p), p }
    assert_equal :intra, route(t, '2.2.2.2/32').path_type
  end

  def test_a_router_without_the_b_bit_is_not_an_abr
    lsas = inter
    lsas[1] = rtr('2.2.2.2', p2p(2, 1))
    assert_nil route(spf(lsas, [iface('eth1', 1, 2)], area: 1), '172.16.0.0/16')
  end

  def test_the_cheapest_summary_wins_and_equal_ones_merge
    lsas = square.each_with_index.map do |l, i|
      i.zero? ? l : rtr(Addr.to_s(l.advr), l.router_links.map { |x| [%i[_ p2p transit stub][x.type], x.id, x.data, x.metric] }, flags: 1)
    end
    lsas += [summary('172.16.0.0', 16, '2.2.2.2', 30), summary('172.16.0.0', 16, '3.3.3.3', 30),
             summary('172.16.0.0', 16, '4.4.4.4', 15)]
    r = route(spf(lsas, square_ifaces, area: 1), '172.16.0.0/16')
    assert_equal 35, r.cost
    assert_equal ['via 10.1.2.2 eth1', 'via 10.1.3.2 eth2'], hops(r)
  end

  def test_an_abr_reads_only_backbone_summaries
    a0 = Spf::Area.new(id: 0, lsas: [rtr('1.1.1.1', p2p(1, 2), flags: 1), rtr('2.2.2.2', p2p(2, 1), flags: 1),
                                     summary('172.16.0.0', 16, '2.2.2.2', 5)],
                       interfaces: [iface('eth1', 1, 2)])
    a1 = Spf::Area.new(id: 1, lsas: [rtr('1.1.1.1', p2p(1, 3), flags: 1), rtr('3.3.3.3', p2p(3, 1), flags: 1),
                                     summary('172.17.0.0', 16, '3.3.3.3', 5)],
                       interfaces: [iface('eth2', 1, 3)])
    t = Spf.run(router_id: '1.1.1.1', areas: [a0, a1])
    assert_equal 15, route(t, '172.16.0.0/16').cost
    assert_nil route(t, '172.17.0.0/16')
  end

  # R1 --10-- R2 (ASBR) ; R1 --10-- R3 --10-- R4 (ASBR)
  def ext_topology
    [
      rtr('1.1.1.1', p2p(1, 2) + p2p(1, 3)),
      rtr('2.2.2.2', p2p(2, 1), flags: 2),
      rtr('3.3.3.3', p2p(3, 1) + p2p(3, 4)),
      rtr('4.4.4.4', p2p(4, 3), flags: 2)
    ]
  end

  def ext_ifaces = [iface('eth1', 1, 2), iface('eth2', 1, 3)]

  def test_type_2_externals_compare_the_type_2_metric_then_the_distance
    t = spf(ext_topology, ext_ifaces, externals: [external('0.0.0.0', 0, '2.2.2.2', 20), external('0.0.0.0', 0, '4.4.4.4', 20)])
    r = route(t, '0.0.0.0/0')
    assert_equal [:ext2, 10, 20], [r.path_type, r.cost, r.type2_cost]
    assert_equal ['via 10.1.2.2 eth1'], hops(r)
    t = spf(ext_topology, ext_ifaces, externals: [external('0.0.0.0', 0, '2.2.2.2', 21), external('0.0.0.0', 0, '4.4.4.4', 20)])
    assert_equal ['via 10.1.3.2 eth2'], hops(route(t, '0.0.0.0/0'))
  end

  def test_type_1_beats_type_2_and_adds_the_distance
    t = spf(ext_topology, ext_ifaces, externals: [external('0.0.0.0', 0, '2.2.2.2', 1), external('0.0.0.0', 0, '4.4.4.4', 50, e2: false)])
    r = route(t, '0.0.0.0/0')
    assert_equal [:ext1, 70], [r.path_type, r.cost]
    assert_equal ['via 10.1.3.2 eth2'], hops(r)
  end

  def test_equal_type_1_externals_merge
    lsas = ext_topology
    lsas[2] = rtr('3.3.3.3', p2p(3, 1) + p2p(3, 4), flags: 2)
    t = spf(lsas, ext_ifaces, externals: [external('9.0.0.0', 8, '2.2.2.2', 5, e2: false, tag: 7),
                                          external('9.0.0.0', 8, '3.3.3.3', 5, e2: false)])
    r = route(t, '9.0.0.0/8')
    assert_equal 15, r.cost
    assert_equal ['via 10.1.2.2 eth1', 'via 10.1.3.2 eth2'], hops(r)
  end

  def test_externals_that_must_be_ignored
    t = spf(ext_topology, ext_ifaces, externals: [
              external('9.1.0.0', 16, '2.2.2.2', Spf::LS_INFINITY),
              external('9.2.0.0', 16, '1.1.1.1', 1),           # our own
              external('9.3.0.0', 16, '3.3.3.3', 1),           # R3 is no ASBR
              external('9.4.0.0', 16, '2.2.2.2', 1, fwd: '203.0.113.1'), # forwarding address unreachable
              external('10.1.3.0', 30, '2.2.2.2', 1)           # internal routes win
            ])
    %w[9.1.0.0/16 9.2.0.0/16 9.3.0.0/16 9.4.0.0/16].each { |p| assert_nil route(t, p), p }
    assert_equal :intra, route(t, '10.1.3.0/30').path_type
  end

  def test_a_forwarding_address_on_our_lan_is_the_next_hop
    lsas = lan
    lsas[1] = rtr('2.2.2.2', [[:transit, '10.0.0.2', '10.0.0.2', 10]], flags: 2)
    t = spf(lsas, lan_ifaces, externals: [external('9.0.0.0', 8, '2.2.2.2', 5, fwd: '10.0.0.3')])
    r = route(t, '9.0.0.0/8')
    assert_equal ['via 10.0.0.3 eth0'], hops(r)
    assert_equal [10, 5], [r.cost, r.type2_cost]
    assert_equal A['10.0.0.3'], r.forwarding
  end

  def test_a_remote_forwarding_address_uses_the_route_to_it
    t = spf(ext_topology, ext_ifaces, externals: [external('9.0.0.0', 8, '2.2.2.2', 5, e2: false, fwd: '10.3.4.2')])
    r = route(t, '9.0.0.0/8')
    assert_equal ['via 10.1.3.2 eth2'], hops(r)
    assert_equal 25, r.cost
  end

  def test_an_asbr_in_another_area_via_a_type_4_summary
    lsas = inter([summary('5.5.5.5', 32, '2.2.2.2', 7, type: 4)])
    t = spf(lsas, [iface('eth1', 1, 2)], area: 1, externals: [external('9.0.0.0', 8, '5.5.5.5', 3, e2: false)])
    r = route(t, '9.0.0.0/8')
    assert_equal [:ext1, 20], [r.path_type, r.cost]
    assert_equal ['via 10.1.2.2 eth1'], hops(r)
  end

  def test_bad_lsas_are_skipped_not_fatal
    bad = Lsa.build(type: 1, ls_id: '7.7.7.7', advr: '7.7.7.7', seq: 1, body: [0, 0, 3].pack('CCn'))
    lsas = square
    lsas[0] = rtr('1.1.1.1', p2p(1, 2) + p2p(1, 3) + [[:p2p, '7.7.7.7', '10.1.7.1', 1]])
    t = spf(lsas + [bad], square_ifaces)
    assert_equal 20, route(t, '4.4.4.4/32').cost
    assert_match(/7\.7\.7\.7/, t.stats[:skipped].join)
  end

  def test_routes_compare_by_value
    a = route(spf(square, square_ifaces), '4.4.4.4/32')
    b = route(spf(square.reverse, square_ifaces.reverse), '4.4.4.4/32')
    assert a.same_as?(b)
    lsas = square
    lsas[0] = rtr('1.1.1.1', p2p(1, 2, 5) + p2p(1, 3))
    refute a.same_as?(route(spf(lsas, square_ifaces), '4.4.4.4/32'))
  end

  # 32 x 32 grid, 1,024 routers, about 4,000 links: well under 200 ms.
  def test_a_thousand_router_grid_is_fast
    n = 32
    id = ->(x, y) { (10 << 24) | (x << 8) | y }
    lsas = []
    (0...n).each do |x|
      (0...n).each do |y|
        links = [[:stub, Addr.to_s(id[x, y] | (1 << 16)), '255.255.255.255', 0]]
        [[x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1]].each do |nx, ny|
          next unless nx.between?(0, n - 1) && ny.between?(0, n - 1)
          links << [:p2p, Addr.to_s(id[nx, ny]), Addr.to_s(id[x, y]), 10]
        end
        lsas << rtr(Addr.to_s(id[x, y]), links)
      end
    end
    ifaces = [Spf::Link.new(name: 'e', address: Addr.to_s(id[0, 0]), prefix_len: 32,
                            neighbors: { Addr.to_s(id[1, 0]) => '192.0.2.1', Addr.to_s(id[0, 1]) => '192.0.2.2' })]
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    t = Spf.run(router_id: Addr.to_s(id[0, 0]), areas: [Spf::Area.new(id: 0, lsas: lsas, interfaces: ifaces)])
    ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
    assert_equal n * n, t.routes.size
    far = t.routes[[id[n - 1, n - 1] | (1 << 16), 32]]
    assert_equal 2 * (n - 1) * 10, far.cost
    assert_equal 2, far.next_hops.size
    limit = ENV['CI'] ? 1000 : 200 # shared CI runners are slow and noisy
    warn format("grid SPF %.1f ms", ms) if ENV["SPF_BENCH"]
    assert_operator ms, :<, limit, format('SPF took %.1f ms', ms)
  end
end
