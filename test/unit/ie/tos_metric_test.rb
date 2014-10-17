require "test/unit"
require "ie/tos_metric"

class TestIeTosMetric < Test::Unit::TestCase
  include OSPFv2
  def tests
    assert TosMetric.new
    assert_equal( '00000000', TosMetric.new.to_shex)
    assert_equal( 'TosMetric: tos: 0 cost: 0', TosMetric.new.to_s)
    assert_equal( '01000001', TosMetric.new(:tos => 1, :cost => 1).to_shex)
    assert_equal( '01ffffff', TosMetric.new(:tos => 1, :cost => 0xffffff).to_shex)
    assert_equal( '01ffffff', TosMetric.new(:tos => 1, :cost => 0xffffffff).to_shex)
    assert_equal( 1, TosMetric.new(:tos => 1, :cost => 0xffffffff).tos)
    assert_equal( 4294967295, TosMetric.new(:tos => 1, :cost => 0xffffffff).cost)
    assert_equal( {:tos=>1, :cost=>1}, TosMetric.new(:tos => 1, :cost => 1).to_hash)
    assert_equal( 'TosMetric: tos: 1 cost: 1', TosMetric.new(:tos => 1, :cost => 1).to_s)
    assert_equal( 'TosMetric: tos: 1 cost: 1', TosMetric.new(:tos => 1, :cost => 1).to_s)
    assert_equal( 'TosMetric: tos: 1 cost: 1', TosMetric.new([1,1]).to_s)
    assert_equal( 'Topology (ID 1) -> Metric: 1', TosMetric.new([1,1]).to_s_junos_style)
    assert_equal( TosMetric.new([1,1]).to_shex, TosMetric.new(TosMetric.new([1,1])).to_shex)
    m = TosMetric.new(['01ffffff'].pack('H*'))
    assert_equal( '01ffffff', m.to_shex)
    assert_equal( 1, m.tos)
    assert_equal( 1, m.id)
    assert_equal( 0xffffff, m.cost)
  end
end