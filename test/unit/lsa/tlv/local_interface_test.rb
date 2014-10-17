require "test/unit"

require "lsa/tlv/local_interface"

class TestTlvLsaLocalInterface < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert_equal("0003000400000000", LocalInterfaceIpAddress_Tlv.new().to_shex)
    assert_equal("Interface Address : 1.1.1.1", LocalInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_s)
    assert_equal("1.1.1.1", LocalInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_hash[:ip_address])
    assert_equal("0003000401010101", LocalInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_shex)
    assert_equal("0003000401010101", LocalInterfaceIpAddress_Tlv.new(LocalInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).encode).to_shex)
  end
end

