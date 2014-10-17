require "test/unit"

require "lsa/tlv/traffic_engineering_metric"

class TestLsaTlvTrafficEngineeringMetric < Test::Unit::TestCase
  include OSPFv2
  def test_test
    assert_equal("0005000400000000", TrafficEngineeringMetric_Tlv.new().to_shex)
    assert_equal("Admin Metric : 254", TrafficEngineeringMetric_Tlv.new({:te_metric=>254}).to_s)
    assert_equal(255, TrafficEngineeringMetric_Tlv.new({:te_metric=>255}).to_hash[:te_metric])
    assert_equal("000500040000ffff", TrafficEngineeringMetric_Tlv.new(TrafficEngineeringMetric_Tlv.new({:te_metric=>0xffff}).encode).to_shex)
    
  end
end

