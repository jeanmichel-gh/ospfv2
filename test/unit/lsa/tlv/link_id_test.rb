require "test/unit"

require "lsa/tlv/link_id"

class TestLsaTlvLinkId < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert_equal("0002000400000000", LinkId_Tlv.new().to_shex)
    assert_equal("Link ID : 1.1.1.1", LinkId_Tlv.new({:link_id=>"1.1.1.1"}).to_s)
    assert_equal("1.1.1.1", LinkId_Tlv.new({:link_id=>"1.1.1.1"}).to_hash[:link_id])
    assert_equal("0002000401010101", LinkId_Tlv.new({:link_id=>"1.1.1.1"}).to_shex)
    assert_equal("0002000401010101", LinkId_Tlv.new(LinkId_Tlv.new({:link_id=>"1.1.1.1"}).encode).to_shex)
  end
end
