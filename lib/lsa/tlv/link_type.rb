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
    attr_reader :tlv_type, :link_type
    def initialize(arg={})
      @tlv_type, @link_type = 1,1
      if arg.is_a?(Hash) then
        set(arg.dup)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end
    def encode
      [@tlv_type, 1, @link_type,0,0,0].pack('nnCC3')
    end
    def __parse(s)
      @tlv_type, _, @link_type= s.unpack('nnC')
    end
    def to_s
      self.class.to_s + ": " + LinkType_Tlv.type_to_s(link_type)
    end
  end
end

load "../../../../test/ospfv2/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
