# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'support/core_lab'

# Virtual links (RFC 2328 15).
#
#   R1 (area 0) -- R2 (ABR 0/1) -- area 1 -- R3 (areas 1 and 2) -- R4 (area 2)
#
# Area 2 touches the backbone only through a virtual link R2 <-> R3
# across area 1. Every router has a passive loopback in its own area
# (R2's in area 0, R3's in area 2).
class TestCoreVirtualLink < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  A = ->(s) { Addr.to_i(s) }
  P2P = { type: :p2p }.freeze

  def setup
    @lab = CoreLab.new
    s12, s23, s34 = Array.new(3) { @lab.segment }
    @r1 = @lab.router('1.1.1.1', [s12, '10.0.12.1/30', P2P], [:passive, '1.1.1.1/32'])
    @r2 = @lab.router('2.2.2.2', [s12, '10.0.12.2/30', P2P], [s23, '10.0.23.1/30', P2P.merge(area: 1)],
                      [:passive, '2.2.2.2/32'])
    @r3 = @lab.router('3.3.3.3', [s23, '10.0.23.2/30', P2P.merge(area: 1)], [s34, '10.0.34.1/30', P2P.merge(area: 2)],
                      [:passive, '3.3.3.3/32', { area: 2 }])
    @r4 = @lab.router('4.4.4.4', [s34, '10.0.34.2/30', P2P.merge(area: 2)], [:passive, '4.4.4.4/32', { area: 2 }])
    @vl2 = @r2.add_virtual_link(neighbor: '3.3.3.3', transit_area: 1)
    @vl3 = @r3.add_virtual_link(neighbor: '2.2.2.2', transit_area: 1)
    @lab.start
  end

  def route(r, prefix)
    p, len = prefix.split('/')
    r.routes[[A[p], len.to_i]]
  end

  def converged? = route(@r1, '4.4.4.4/32') && route(@r4, '1.1.1.1/32')

  def test_area_2_reaches_the_backbone_through_the_virtual_link
    assert @lab.run_until(180) { converged? }, @lab.log.last(20).join("\n")
    assert @vl2.full_neighbors.any? && @vl3.full_neighbors.any?
    assert_equal [10, A['10.0.23.1'], A['10.0.23.2']], [@vl2.cost, @vl2.address, @vl2.remote]
    links = @r2.areas[0].lsdb[[1, @r2.router_id, @r2.router_id]].router_links
    assert(links.any? { |l| l.type == 4 && l.id == A['3.3.3.3'] && l.data == A['10.0.23.1'] && l.metric == 10 })
    assert_equal 4, @r2.areas[1].lsdb[[1, @r2.router_id, @r2.router_id]].router_body[0] & 4, 'V bit in the transit area'
    assert @r3.abr?, 'the virtual link attaches R3 to the backbone'
    r = route(@r1, '4.4.4.4/32')
    assert_equal [:inter, 40], [r.path_type, r.cost], 'R1-R2 10, virtual link 10, R3-R4 10, loopback 10'
    assert_equal ['via 10.0.12.2 eth0'], r.next_hops.map(&:to_s)
    assert_equal :inter, route(@r4, '1.1.1.1/32').path_type
    r = route(@r3, '1.1.1.1/32')
    assert_equal ['via 10.0.23.1 eth0'], r.next_hops.map(&:to_s), 'traffic over the virtual link takes the transit path'
    assert_equal 0, r.area, 'a backbone route, through the virtual link'
    assert_empty @vl2.neighbors.values.flat_map { |n| n.retransmit.keys }.select { |k| k[0] == 5 }
  end

  def test_the_virtual_link_falls_when_the_transit_path_does
    assert @lab.run_until(180) { converged? }
    @r2.remove_interface('eth1')
    assert @lab.run_until(120) { route(@r1, '4.4.4.4/32').nil? }
    assert @lab.run_until(60) { !@vl3.up? }
    refute @r3.abr?
  end

  def test_virtual_links_carry_no_as_externals
    assert @lab.run_until(180) { converged? }
    @r1.externals = [{ prefix: A['192.0.2.0'], prefix_len: 24, metric: 20, type: 2, tag: 0 }]
    assert @lab.run_until(60) { route(@r4, '192.0.2.0/24') }, 'it still reaches area 2, through area 1'
    sent = @vl2.stats[:tx_ls_update]
    assert_operator sent, :>, 0
    refute(@r3.instance_variable_get(:@interfaces)['vl-2.2.2.2'].stats[:drop_lsa].positive?, 'nothing to refuse')
  end

  def test_a_virtual_link_cannot_cross_the_backbone
    assert_raise(ArgumentError) { @r1.add_virtual_link(neighbor: '2.2.2.2', transit_area: 0) }
  end

  # ---- review fixes ----

  def test_backbone_routes_over_the_link_are_not_summarized_back_into_the_transit_area
    assert @lab.run_until(180) { converged? }
    into1 = @r3.areas[1].lsdb.select { |l| l.type == 3 && l.advr == @r3.router_id && !l.max_age? }.map { |l| Addr.to_s(l.ls_id) }
    assert_include into1, '4.4.4.4', 'area 2 goes into area 1'
    %w[1.1.1.1 2.2.2.2 10.0.12.0].each { |p| assert_not_include into1, p, 'reached through area 1: split horizon' }
  end

  def test_packets_for_the_neighbor_go_to_the_far_end_and_no_externals_on_request
    assert @lab.run_until(180) { converged? }
    n = @vl3.full_neighbors.first
    assert_equal @vl3.remote, n.unicast_destination
    @r1.externals = [{ prefix: A['192.0.2.0'], prefix_len: 24, metric: 20, type: 2, tag: 0 }]
    assert @lab.run_until(30) { @r2.as_lsdb[[5, A['192.0.2.0'], A['1.1.1.1']]] }
    n2 = @vl2.full_neighbors.first
    n2.receive_ls_request(Wire::LinkStateRequest.new(requests: [[5, A['192.0.2.0'], A['1.1.1.1']]]))
    assert_equal :exstart, n2.state, 'BadLSReq: no AS-external LSAs over a virtual link'
  end

  def test_a_virtual_link_waits_for_spf_to_come_up
    lab = CoreLab.new
    r = lab.router('9.9.9.9', [lab.segment, '10.9.0.1/30', P2P.merge(area: 1)])
    vl = r.add_virtual_link(neighbor: '2.2.2.2', transit_area: 1)
    r.start
    refute vl.up?, 'nothing reaches 2.2.2.2 yet'
    refute r.abr?
  end

  # The far end has another interface in the transit area, listed first
  # in its router-LSA: the address used is the one on the path to us.
  def test_the_far_end_address_is_on_the_path_toward_us
    lab = CoreLab.new
    s26, s25, s53 = Array.new(3) { lab.segment }
    a1 = P2P.merge(area: 1)
    lab.router('6.6.6.6', [s26, '10.0.26.2/30', a1])
    r2 = lab.router('2.2.2.2', [s26, '10.0.26.1/30', a1], [s25, '10.0.25.1/30', a1], [:passive, '2.2.2.2/32'])
    lab.router('5.5.5.5', [s25, '10.0.25.2/30', a1], [s53, '10.0.35.1/30', a1])
    r3 = lab.router('3.3.3.3', [s53, '10.0.35.2/30', a1], [:passive, '3.3.3.3/32', { area: 2 }])
    vl = r3.add_virtual_link(neighbor: '2.2.2.2', transit_area: 1)
    r2.add_virtual_link(neighbor: '3.3.3.3', transit_area: 1)
    lab.start
    assert lab.run_until(120) { vl.up? }
    assert_equal A['10.0.25.1'], vl.remote, 'not 10.0.26.1, which r3 cannot reach on its own link'
    assert_equal 'eth0', vl.via
  end
end
