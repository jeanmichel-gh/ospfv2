require "test/unit"

require "lsa/tlv/maximum_reservable_bandwidth"

class TestLsaTlvMaximumReservableBandwitdh < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert_equal("0007000400000000", MaximumReservableBandwidth_Tlv.new().to_shex)
    assert_equal("Maximum reservable bandwidth : 10000", MaximumReservableBandwidth_Tlv.new({:max_resv_bw=>10_000}).to_s)
    assert_equal(255, MaximumReservableBandwidth_Tlv.new({:max_resv_bw=>255}).to_hash[:max_resv_bw])
    assert_equal("0007000445ffff00", MaximumReservableBandwidth_Tlv.new({:max_resv_bw=>0xffff}).to_shex)
  end
end