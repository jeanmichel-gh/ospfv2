require "test/unit"

require "lsa/tlv/link_type"

class TestLsaTlvLinkType < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert_equal("0001000101000000", LinkType_Tlv.new().to_shex)
    assert_equal("Link Type : p2p", LinkType_Tlv.new({:link_type=>1}).to_s)
    assert_equal("Link Type : multiaccess", LinkType_Tlv.new({:link_type=>2}).to_s)
    assert_equal(1, LinkType_Tlv.new({:link_type=>1}).to_hash[:link_type])
    assert_equal("0001000101000000", LinkType_Tlv.new({:link_type=>1}).to_shex)
    assert_equal("0001000101000000", LinkType_Tlv.new(LinkType_Tlv.new({:link_type=>1}).encode).to_shex)
    assert_equal(true, LinkType_Tlv.new({:link_type=>1}).kind_of?(SubTlv))
  end
end
