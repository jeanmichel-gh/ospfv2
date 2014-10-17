require "test/unit"

require "ie/metric"

class TestIeMetric < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert Metric
    assert_equal( '00000000', Metric.new.to_shex)
    assert_equal( 'Metric: 0', Metric.new.to_s)
    assert_equal( 0, Metric.new.to_i)
    assert_equal( '000000ff', Metric.new(255).to_shex)
    assert_equal( 'Metric: 255', Metric.new(255).to_s)
    assert_equal( 255, Metric.new(255).to_i)
    assert_raise(RuntimeError)  { Metric.new 0xffffffff }
    assert_raise(RuntimeError)  { Metric.new 0xfffffff }
    assert_raise(RuntimeError)  { Metric.new 0x1ffffff }
    assert_raise(RuntimeError)  { Metric.new( -1) }
    assert_equal( 'Metric: 16777215', Metric.new(0x0ffffff).to_s)
    assert_equal( 'Topology default (ID 0) -> Metric: 16777215', Metric.new(0x0ffffff).to_s_junos)
    assert_equal( '000fffff', Metric.new(0xfffff).to_shex)
    assert_equal( 'ffff', Metric.new(0xfffff).to_shex('n'))
  end
end
