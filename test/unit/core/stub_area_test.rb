# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'support/core_lab'

# Stub areas (RFC 2328 3.6, 12.4.3.1).
#
#   R1 (area 0, ASBR) -- R2 (ABR 0/1) -- R3 (area 1, stub)
class TestCoreStubArea < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  A = ->(s) { Addr.to_i(s) }
  P2P = { type: :p2p }.freeze

  def build(stub)
    @lab = CoreLab.new
    s12 = @lab.segment
    @s23 = @lab.segment
    @r1 = @lab.router('1.1.1.1', [s12, '10.0.12.1/30', P2P])
    @r2 = @lab.router('2.2.2.2', [s12, '10.0.12.2/30', P2P], [@s23, '10.0.23.1/30', P2P.merge(area: 1)])
    @r3 = @lab.router('3.3.3.3', [@s23, '10.0.23.2/30', P2P.merge(area: 1)])
    [@r2, @r3].each { |r| r.area_options = { 1 => { stub: stub } } }
    @lab.start
    @r1.externals = [{ prefix: A['192.0.2.0'], prefix_len: 24, metric: 20, type: 2, tag: 0 }]
    assert @lab.run_until(120) { @r3.routes.key?([0, 0]) && @r1.routes.key?([A['10.0.23.0'], 30]) }
    @lab.advance(10)
  end

  def area1_lsas(r, type) = r.areas[1].lsdb.select { |l| l.type == type && !l.max_age? }.map { |l| Addr.to_s(l.ls_id) }.sort

  def test_a_stub_area_gets_a_default_and_no_externals
    build({})
    d = @r3.routes[[0, 0]]
    assert_equal [:inter, 11], [d.path_type, d.cost], 'default cost 1 + the link'
    assert_empty @r3.as_lsdb.to_a, 'no AS-external LSAs in a stub area'
    assert_nil @r3.routes[[A['192.0.2.0'], 24]]
    assert_include area1_lsas(@r3, 3), '10.0.12.0', 'summaries still come in'
    assert_empty area1_lsas(@r3, 4), 'no ASBR summaries'
    assert_equal 0, @r3.areas[1].lsdb[[1, @r3.router_id, @r3.router_id]].options & 0x02, 'E bit clear'
    assert_equal 0x02, @r1.areas[0].lsdb[[1, @r1.router_id, @r1.router_id]].options & 0x02
  end

  def test_totally_stubby_gets_only_the_default
    build({ no_summaries: true, default_metric: 5 })
    assert_equal ['0.0.0.0'], area1_lsas(@r3, 3)
    assert_equal 15, @r3.routes[[0, 0]].cost
  end

  def test_an_asbr_in_a_stub_area_keeps_its_externals_out_of_it
    build({})
    @r2.externals = [{ prefix: A['198.51.100.0'], prefix_len: 24, metric: 20, type: 2, tag: 0 }]
    assert @lab.run_until(30) { @r1.routes.key?([A['198.51.100.0'], 24]) }
    assert_empty @r3.as_lsdb.to_a
    flags = ->(a) { @r2.areas[a].lsdb[[1, @r2.router_id, @r2.router_id]].router_body[0] }
    assert_equal 2, flags[0] & 2, 'E bit in the backbone'
    assert_equal 0, flags[1] & 2, 'not in the stub area'
  end

  def test_a_router_that_disagrees_about_the_stub_flag_is_kept_out
    build({})
    r4 = @lab.router('4.4.4.4', [@s23, '10.0.23.3/30', P2P.merge(area: 1)], start: true)
    @lab.advance(30)
    assert_empty r4.neighbors.select(&:full?)
    assert_operator @r3.interfaces['eth0'].stats[:drop_hello], :>, 0
    assert_match(/E bit mismatch/, @lab.log.join("\n"))
  end
end
