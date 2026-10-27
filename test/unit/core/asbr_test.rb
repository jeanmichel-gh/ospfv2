# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'support/core_lab'

# AS boundary routers: AS-external-LSAs and the E bit (RFC 2328 12.4.4).
#
#   R1 (area 0) -- R2 (ABR 0/1) -- R3 (area 1, ASBR)
class TestCoreAsbr < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  A = ->(s) { Addr.to_i(s) }

  def setup
    @lab = CoreLab.new
    s12 = @lab.segment
    s23 = @lab.segment
    p2p = { type: :p2p }
    @r1 = @lab.router('1.1.1.1', [s12, '10.0.12.1/30', p2p])
    @r2 = @lab.router('2.2.2.2', [s12, '10.0.12.2/30', p2p], [s23, '10.0.23.1/30', p2p.merge(area: 1)])
    @r3 = @lab.router('3.3.3.3', [s23, '10.0.23.2/30', p2p.merge(area: 1)])
    @lab.start
    assert @lab.run_until(120) { @r1.routes.key?([A['10.0.23.0'], 30]) }
  end

  def ext(prefix, metric, type, tag = 0)
    p, len = prefix.split('/')
    { prefix: A[p], prefix_len: len.to_i, metric: metric, type: type, tag: tag }
  end

  def route(r, prefix)
    p, len = prefix.split('/')
    r.routes[[A[p], len.to_i]]
  end

  def e_bit(r, area) = r.areas[area].lsdb[[1, r.router_id, r.router_id]].router_body[0] & 2

  def test_externals_reach_every_area
    @r3.externals = [ext('192.0.2.0/24', 20, 2, 7), ext('198.51.100.0/24', 5, 1)]
    assert @lab.run_until(30) { route(@r1, '192.0.2.0/24') && route(@r1, '198.51.100.0/24') }
    assert @r3.asbr?
    assert_equal 2, e_bit(@r3, 1)
    r = route(@r1, '192.0.2.0/24')
    assert_equal [:ext2, 20, 20, 7], [r.path_type, r.cost, r.type2_cost, r.tag], 'internal cost 20 to the ASBR'
    r = route(@r1, '198.51.100.0/24')
    assert_equal [:ext1, 25], [r.path_type, r.cost]
    assert_equal :inter, @r1.route_table.routers.values.find { |x| x.prefix == A['3.3.3.3'] }.path_type,
                 'the ASBR is reached through the ABR\'s type 4 summary'
    lsa = @r1.as_lsdb[[5, A['192.0.2.0'], A['3.3.3.3']]]
    mask, m, fwd, tag = lsa.body.unpack('NNNN')
    assert_equal [A['255.255.255.0'], 0x8000_0014, 0, 7], [mask, m, fwd, tag]
  end

  def test_withdrawn_externals_are_flushed_and_the_e_bit_cleared
    @r3.externals = [ext('192.0.2.0/24', 20, 2)]
    assert @lab.run_until(30) { route(@r1, '192.0.2.0/24') }
    @r3.externals = []
    assert @lab.run_until(30) { route(@r1, '192.0.2.0/24').nil? }
    refute @r3.asbr?
    assert @lab.run_until(30) { e_bit(@r3, 1).zero? }
  end

  def test_a_changed_metric_is_reoriginated
    @r3.externals = [ext('192.0.2.0/24', 20, 2)]
    assert @lab.run_until(30) { route(@r1, '192.0.2.0/24') }
    @r3.externals = [ext('192.0.2.0/24', 50, 2)]
    assert @lab.run_until(30) { route(@r1, '192.0.2.0/24').type2_cost == 50 }
  end

  def test_externals_set_before_an_interface_is_up_go_out_when_one_is
    lab = CoreLab.new
    seg = lab.segment
    a = lab.router('1.1.1.1', [seg, '10.0.0.1/30', { type: :p2p }])
    b = lab.router('2.2.2.2', [seg, '10.0.0.2/30', { type: :p2p }])
    b.externals = [ext('192.0.2.0/24', 20, 2)]
    lab.start
    assert lab.run_until(60) { a.routes.key?([A['192.0.2.0'], 24]) }
  end
end
