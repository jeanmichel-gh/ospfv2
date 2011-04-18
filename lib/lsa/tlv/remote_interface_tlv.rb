
=begin rdoc

2.5.4.  Remote Interface IP Address

The Remote Interface IP Address sub-TLV specifies the IP address(es)
of the neighbor's interface corresponding to this link.  This and the
Remote address are used to discern multiple parallel links between
systems.  If the Link Type of the link is Multi-access, the Remote
Interface IP Address is set to 0.0.0.0; alternatively, an
implementation MAY choose not to send this sub-TLV.

The Remote Interface IP Address sub-TLV is TLV type 4, and is 4N
octets in length, where N is the number of neighbor addresses.

=end


require 'lsa/tlv/tlv'

module OSPFv2

  class RemoteInterfaceIpAddress_Tlv
    include SubTlv
    include Common

    IpAddress = Class.new(Id) unless const_defined?(:IpAddress)
    attr_reader :tlv_type, :length, :ip_address

    attr_writer_delegate :ip_address

    def initialize(arg={})
      @tlv_type, @length,  = 4,4
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
    assert_equal("0004000400000000", RemoteInterfaceIpAddress_Tlv.new().to_shex)
    assert_equal("OSPFv2::RemoteInterfaceIpAddress_Tlv: 1.1.1.1", RemoteInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_s)
    assert_equal("1.1.1.1", RemoteInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_hash[:ip_address])
    assert_equal("0004000401010101", RemoteInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).to_shex)
    assert_equal("0004000401010101", RemoteInterfaceIpAddress_Tlv.new(RemoteInterfaceIpAddress_Tlv.new({:ip_address=>"1.1.1.1"}).encode).to_shex)
  end
end

end
