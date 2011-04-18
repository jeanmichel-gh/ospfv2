=begin rdoc  

2.5.1.  Link Type

The Link Type sub-TLV defines the type of the link:

1 - Point-to-point
2 - Multi-access

The Link Type sub-TLV is TLV type 1, and is one octet in length.

=end

require 'lsa/tlv/tlv'

module OSPFv2
  class LinkType_Tlv
    @link_type = { 1=> :p2p, 2=> :multiaccess }
    class << self
      def type_to_s(arg)
        "#{@link_type[arg]}"
      end
    end
    include SubTlv
    include Common
    attr_reader :tlv_type, :length, :link_type
    def initialize(arg={})
      @tlv_type, @length, @link_type = 1,1,1
      if arg.is_a?(Hash) then
        set(arg)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end
    def encode
      [@tlv_type, @length, @link_type,0,0,0].pack('nnCC3')
    end
    def __parse(s)
      @tlv_type, _, @link_type= s.unpack('nnC')
    end
    def to_s
      self.class.to_s + ": " + LinkType_Tlv.type_to_s(link_type)
    end
  end
end

if __FILE__ == $0
  require "test/unit"
  # require "tlv/tlv"
  class LinkType_TlvTlv_Test < Test::Unit::TestCase # :nodoc:
    include OSPFv2
    def test_init
      assert_equal("0001000101000000", LinkType_Tlv.new().to_shex)
      assert_equal("OSPFv2::LinkType_Tlv: p2p", LinkType_Tlv.new({:link_type=>1}).to_s)
      assert_equal("OSPFv2::LinkType_Tlv: multiaccess", LinkType_Tlv.new({:link_type=>2}).to_s)
      assert_equal(1, LinkType_Tlv.new({:link_type=>1}).to_hash[:link_type])
      assert_equal("0001000101000000", LinkType_Tlv.new({:link_type=>1}).to_shex)
      assert_equal("0001000101000000", LinkType_Tlv.new(LinkType_Tlv.new({:link_type=>1}).encode).to_shex)
      assert_equal(true, LinkType_Tlv.new({:link_type=>1}).kind_of?(SubTlv))
    end
  end
end
