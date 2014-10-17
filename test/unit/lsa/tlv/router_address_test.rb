require "test/unit"

require "lsa/tlv/router_address"

class TestLsaTlvRouterAddress < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert_equal("0001000400000000", RouterAddress_Tlv.new().to_shex)
    assert_equal("RouterID TLV: 1.1.1.1", RouterAddress_Tlv.new(:ip_address=>"1.1.1.1").to_s)
    assert_equal("1.1.1.1", RouterAddress_Tlv.new(:ip_address=>"1.1.1.1").to_hash[:ip_address])
    assert_equal("0001000401010101", RouterAddress_Tlv.new(:ip_address=>"1.1.1.1").to_shex)
    assert_equal("0001000401010101", RouterAddress_Tlv.new(RouterAddress_Tlv.new(:ip_address=>"1.1.1.1").encode).to_shex)
    assert_equal(true, RouterAddress_Tlv.new(:ip_address=>"1.1.1.1").is_a?(Tlv))
    assert_equal(1, RouterAddress_Tlv.new(:ip_address=>"1.1.1.1").tlv_type)
  end
end
