require "test/unit"

require "lsa/tlv/maximum_bandwidth"

class TestLsaTlvMaximumBandwidth < Test::Unit::TestCase
  include OSPFv2
  def test_case_name
    assert_equal("0006000400000000", MaximumBandwidth_Tlv.new().to_shex)
    assert_equal("Maximum bandwidth : 10000", MaximumBandwidth_Tlv.new( :max_bw=>10_000.0 ).to_s)
    assert_equal("00060004449c4000", MaximumBandwidth_Tlv.new( :max_bw=>10_000.0 ).to_shex)
    assert_equal(10000, MaximumBandwidth_Tlv.new( :max_bw=>10_000.0 ).to_hash[:max_bw])
    assert_equal("00060004449c4000", MaximumBandwidth_Tlv.new(['00060004449c4000'].pack('H*')).to_shex)
  end
end
