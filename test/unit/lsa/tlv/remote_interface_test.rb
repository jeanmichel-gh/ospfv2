require "test/unit"

require "lsa/tlv/remote_interface"

class TestLsaTlvRemoteInterface < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert_equal("0004000400000000", RemoteInterfaceIpAddress_Tlv.new().to_shex)
    assert_equal("Neighbor Address : 1.1.1.1", RemoteInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_s)
    assert_equal("1.1.1.1", RemoteInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_hash[:ip_address])
    assert_equal("0004000401010101", RemoteInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_shex)
    assert_equal("0004000401010101", RemoteInterfaceIpAddress_Tlv.new(RemoteInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).encode).to_shex)
  end
end
