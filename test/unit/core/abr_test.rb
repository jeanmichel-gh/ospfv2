# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'support/core_lab'

# Area border routers: the B bit and summary-LSAs (RFC 2328 12.4.3).
#
#   R3 (area 1) -- R2 (ABR 0/1) -- R1 (area 0) -- R4 (ABR 0/2) -- R5 (area 2)
#
# All links point-to-point, every router with a passive loopback in its
# own area (the ABRs' in area 0).
class TestCoreAbr < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  A = ->(s) { Addr.to_i(s) }

  def setup
    @lab = CoreLab.new
    s12, s23, s14, s45 = Array.new(4) { @lab.segment }
    p2p = { type: :p2p }
    @r1 = @lab.router('1.1.1.1', [s12, '10.0.12.1/30', p2p], [s14, '10.0.14.1/30', p2p], [:passive, '1.1.1.1/32'])
    @r2 = @lab.router('2.2.2.2', [s12, '10.0.12.2/30', p2p], [s23, '10.0.23.1/30', p2p.merge(area: 1)],
                      [:passive, '2.2.2.2/32'])
    @r3 = @lab.router('3.3.3.3', [s23, '10.0.23.2/30', p2p.merge(area: 1)], [:passive, '3.3.3.3/32', { area: 1 }])
    @r4 = @lab.router('4.4.4.4', [s14, '10.0.14.2/30', p2p], [s45, '10.0.45.1/30', p2p.merge(area: 2)],
                      [:passive, '4.4.4.4/32'])
    @r5 = @lab.router('5.5.5.5', [s45, '10.0.45.2/30', p2p.merge(area: 2)], [:passive, '5.5.5.5/32', { area: 2 }])
    @lab.start
  end

  def route(r, prefix)
    p, len = prefix.split('/')
    r.routes[[A[p], len.to_i]]
  end

  def converged?
    route(@r3, '5.5.5.5/32') && route(@r5, '3.3.3.3/32') && route(@r1, '3.3.3.3/32') && route(@r1, '5.5.5.5/32')
  end

  def summaries(r, area, type = 3)
    r.areas[A[area]].lsdb.select { |l| l.type == type && l.advr == r.router_id && !l.max_age? }
     .map { |l| Addr.to_s(l.ls_id) }.sort
  end

  def test_abrs_set_the_b_bit_and_others_do_not
    assert @lab.run_until(120) { converged? }
    assert @r2.abr?
    refute @r1.abr?
    [0, 1].each do |area|
      flags, = @r2.areas[area].lsdb[[1, @r2.router_id, @r2.router_id]].router_body
      assert_equal 1, flags & 1, "B bit in area #{area}"
    end
    flags, = @r1.areas[0].lsdb[[1, @r1.router_id, @r1.router_id]].router_body
    assert_equal 0, flags & 1
  end

  # A router in two areas has one router-LSA key but two LSAs: each must
  # be originated on its own (it once shared MinLSInterval and the
  # "unchanged" check with the other area, and area 1 kept a stale copy).
  def test_each_area_gets_its_own_router_lsa
    assert @lab.run_until(120) { converged? }
    links = ->(area) { @r2.areas[area].lsdb[[1, @r2.router_id, @r2.router_id]].router_body[1].map(&:type_name).sort }
    assert_equal %i[p2p stub stub], links[0], 'eth0 and the loopback'
    assert_equal %i[p2p stub], links[1], 'eth1'
  end

  def test_routes_cross_areas_through_summaries
    assert @lab.run_until(120) { converged? }
    r = route(@r3, '1.1.1.1/32')
    assert_equal :inter, r.path_type
    assert_equal 30, r.cost, 'p2p 10 + p2p 10 + loopback 10'
    assert_equal ['via 10.0.23.1 eth0'], r.next_hops.map(&:to_s)
    r = route(@r3, '5.5.5.5/32')
    assert_equal :inter, r.path_type, 'area 2 reaches area 1 over the backbone'
    assert_equal 50, r.cost
    assert_equal :inter, route(@r1, '3.3.3.3/32').path_type
  end

  def test_what_each_area_is_told
    assert @lab.run_until(120) { converged? }
    into1 = summaries(@r2, '0.0.0.1')
    assert_include into1, '1.1.1.1', 'backbone network'
    assert_include into1, '10.0.12.0'
    assert_include into1, '5.5.5.5', 'an inter-area route goes on into a non-backbone area'
    assert_not_include into1, '3.3.3.3', 'never a network of the area itself'
    into0 = summaries(@r2, '0.0.0.0')
    assert_equal %w[10.0.23.0 3.3.3.3], into0, 'the backbone hears area 1 only, not inter-area routes back'
    assert_empty summaries(@r1, '0.0.0.0'), 'not an ABR'
  end

  def test_an_abr_that_leaves_an_area_withdraws_its_summaries
    assert @lab.run_until(120) { converged? }
    @r2.remove_interface('eth1')
    assert @lab.run_until(60) { route(@r1, '3.3.3.3/32').nil? }
    refute @r2.abr?
    assert_empty summaries(@r2, '0.0.0.0')
    flags, = @r2.areas[0].lsdb[[1, @r2.router_id, @r2.router_id]].router_body
    assert_equal 0, flags & 1, 'B bit cleared'
  end

  def test_a_changed_cost_updates_the_summary
    assert @lab.run_until(120) { converged? }
    @r1.interfaces['eth1'].cost = 40
    assert @lab.run_until(60) { route(@r3, '5.5.5.5/32')&.cost == 80 }
  end

  # ---- summaries_for on hand-made tables ----

  def make_route(prefix, len, type, cost, area, hops = [])
    Spf::Route.new(prefix: A[prefix], prefix_len: len, path_type: type, cost: cost, area: area && A[area],
                   next_hops: hops.map { |i, g| Spf::NextHop.new(i, g && A[g]) })
  end

  def table(routes, routers = [])
    Spf::Table.new(routes: routes.to_h { |r| [[r.prefix, r.prefix_len], r] },
                   routers: routers.to_h { |r| [[r.prefix, r.area], r] }, stats: { skipped: [] })
  end

  def specs(table, area)
    @r2.send(:summaries_for, @r2.areas[A[area]], table).values
       .map { |s| [s[:type], Addr.to_s(s[:ls_id]), *s[:body].unpack('NN').then { |m, c| [Addr.to_s(m), c] }] }.sort
  end

  def test_appendix_e_link_state_ids
    t = table([make_route('10.9.0.0', 16, :intra, 5, '0.0.0.0'), make_route('10.9.0.0', 24, :intra, 6, '0.0.0.0')])
    assert_equal [[3, '10.9.0.0', '255.255.0.0', 5], [3, '10.9.0.255', '255.255.255.0', 6]], specs(t, '0.0.0.1')
  end

  def test_inter_area_routes_are_not_sent_back_where_they_come_from
    t = table([make_route('9.0.0.0', 8, :inter, 30, '0.0.0.0', [['eth1', '10.0.23.2']]),
               make_route('9.1.0.0', 16, :inter, 30, '0.0.0.0', [['eth0', '10.0.12.1']]),
               make_route('9.2.0.0', 16, :ext2, 1, nil),
               make_route('9.3.0.0', 16, :intra, Spf::LS_INFINITY, '0.0.0.0')])
    assert_equal [[3, '9.1.0.0', '255.255.0.0', 30]], specs(t, '0.0.0.1'),
                 'one leaves by area 1 (split horizon); externals and unreachable never'
  end

  def test_asbrs_get_type_4_summaries
    asbr = Spf::Route.new(prefix: A['7.7.7.7'], prefix_len: 32, path_type: :intra, cost: 12, area: A['0.0.0.1'],
                          next_hops: [], tag: { abr: false, asbr: true })
    t = table([], [asbr])
    assert_equal [[4, '7.7.7.7', '0.0.0.0', 12]], specs(t, '0.0.0.0')
    assert_empty specs(t, '0.0.0.1'), 'the ASBR is in that area'
  end

  def test_appendix_e_says_once_when_ids_run_out
    t = table([make_route('10.9.0.0', 16, :intra, 5, '0.0.0.0'), make_route('10.9.0.0', 24, :intra, 6, '0.0.0.0'),
               make_route('10.9.0.255', 32, :intra, 7, '0.0.0.0')])
    2.times { specs(t, '0.0.0.1') }
    assert_equal 1, @lab.log.count { |l| l.include?('no link state id left for 10.9.0.255/32') }
  end

  def test_nothing_is_redone_when_nothing_changed
    assert @lab.run_until(120) { converged? }
    @lab.advance(15)
    calls = 0
    @r2.define_singleton_method(:summaries_for) { |*a| calls += 1; super(*a) }
    3.times { @r2.compute_routes }
    assert_equal 0, calls
    @r1.interfaces['eth1'].cost = 40
    assert @lab.run_until(30) { calls.positive? }
  end

  # RFC 3509: a router in two areas, neither the backbone, is no ABR.
  def test_two_areas_without_the_backbone_make_no_abr
    lab = CoreLab.new
    a = lab.segment
    b = lab.segment
    r = lab.router('7.7.7.7', [a, '10.7.1.1/30', { type: :p2p, area: 1 }], [b, '10.7.2.1/30', { type: :p2p, area: 2 }])
    lab.start
    lab.advance(5)
    refute r.abr?
    assert_equal 0, r.areas[1].lsdb[[1, r.router_id, r.router_id]].router_body[0] & 1
  end
end
