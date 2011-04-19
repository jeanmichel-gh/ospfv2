
=begin rdoc  

2.5.2.  Link ID

The Link ID sub-TLV identifies the other end of the link.  For
point-to-point links, this is the Router ID of the neighbor.  For
multi-access links, this is the interface address of the designated
router.  The Link ID is identical to the contents of the Link ID
field in the Router LSA for these link types.

The Link ID sub-TLV is TLV type 2, and is four octets in length.

=end


require 'lsa/tlv/tlv'

module OSPFv2

  class LinkId_Tlv
    include SubTlv
    include Common

    LinkId = Class.new(Id) unless const_defined?(:LinkId)
    attr_reader :tlv_type, :link_id

    attr_writer_delegate :link_id

    def initialize(arg={})
      @tlv_type, @_length,  = 2,4
      @link_id = LinkId.new

      if arg.is_a?(Hash) then
        set(arg.dup)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, @_length, @link_id.encode].pack('nna*')
    end

    def __parse(s)
      @tlv_type, _, link_id = s.unpack('nna*')
      @link_id = LinkId.new_ntoh(link_id)
    end


    def to_s
      self.class.to_s + ": " + link_id.to_ip
    end

    def to_s_junos_style(ident=0)
      "  "*ident + "RtrAddr (1), length #{@length}: #{router_id.to_ip}"
    end

  end
end

load "../../../../test/ospfv2/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
