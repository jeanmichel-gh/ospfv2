require "test/unit"
require "ie/mt_metric"

class TestIeMtMetric < Test::Unit::TestCase
  include OSPFv2
  def tests
    assert MtMetric.new
    assert_equal '00000000', MtMetric.new.to_shex
    assert_equal 'Topology 0, Metric 0', MtMetric.new.to_s
    assert_equal '01000001', MtMetric.new(:id => 1, :metric => 1).to_shex
    assert_equal '01ffffff', MtMetric.new(:id => 1, :metric => 0xffffff).to_shex
    assert_equal '01ffffff', MtMetric.new(:id => 1, :metric => 0xffffffff).to_shex
    assert_equal 1, MtMetric.new(:id => 1, :metric => 0xffffffff).id
    assert_equal 4294967295, MtMetric.new(:id => 1, :metric => 0xffffffff).metric
    assert_equal( {:id=>1, :metric=>1}, MtMetric.new(:id => 1, :metric => 1).to_hash)
    assert_equal( 'Topology 1, Metric 1', MtMetric.new(:id => 1, :metric => 1).to_s)
    assert_equal( 'Topology 1, Metric 1', MtMetric.new(:id => 1, :metric => 1).to_s)
    assert_equal( 'Topology 1, Metric 1', MtMetric.new([1,1]).to_s)
    assert_equal 'Topology (ID 1) -> Metric: 1', MtMetric.new([1,1]).to_s_junos
    assert_equal MtMetric.new([1,1]).to_shex, MtMetric.new(MtMetric.new([1,1])).to_shex
    m = MtMetric.new(['01ffffff'].pack('H*'))
    assert_equal '01ffffff', m.to_shex
    assert_equal 1, m.id
    assert_equal 1, m.id
    assert_equal 0xffffff, m.metric
  end
end