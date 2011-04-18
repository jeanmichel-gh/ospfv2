=begin rdoc  

2.5.3.  Local Interface IP Address

The Local Interface IP Address sub-TLV specifies the IP address(es)
of the interface corresponding to this link.  If there are multiple
local addresses on the link, they are all listed in this sub-TLV.

The Local Interface IP Address sub-TLV is TLV type 3, and is 4N
octets in length, where N is the number of local addresses.

=end

require 'lsa/tlv/tlv'

module OSPFv2

  class LocalInterfaceIpAddress_Tlv
    include SubTlv
    include Common

    IpAddress = Class.new(Id) unless const_defined?(:IpAddress)
    attr_reader :tlv_type, :length, :ip_address

    attr_writer_delegate :ip_address

    def initialize(arg={})
      @tlv_type, @length,  = 3,4
      @ip_address = IpAddress.new

      if arg.is_a?(Hash) then
        set(arg)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, @length, @ip_address.encode].pack('nna*')
    end

    def __parse(s)
      @tlv_type, _, ip_address = s.unpack('nna*')
      @ip_address = IpAddress.new_ntoh(ip_address)
    end


    def to_s
      self.class.to_s + ": " + ip_address.to_ip
    end

    def to_s_junos_style(ident=0)
      "  "*ident + "RtrAddr (1), length #{@length}: #{router_id.to_ip}"
    end

  end
end

if __FILE__ == $0
  require "test/unit"

class IpAddress_SubTLV_Test < Test::Unit::TestCase # :nodoc:
  include OSPFv2
  def test_init
    assert_equal("0003000400000000", LocalInterfaceIpAddress_Tlv.new().to_shex)
    assert_equal("OSPFv2::LocalInterfaceIpAddress_Tlv: 1.1.1.1", LocalInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_s)
    assert_equal("1.1.1.1", LocalInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_hash[:ip_address])
    assert_equal("0003000401010101", LocalInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_shex)
    assert_equal("0003000401010101", LocalInterfaceIpAddress_Tlv.new(LocalInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).encode).to_shex)
  end
end

end
