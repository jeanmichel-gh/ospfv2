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
    attr_reader :tlv_type, :ip_address

    attr_writer_delegate :ip_address

    def initialize(arg={})
      @tlv_type = 3
      @ip_address = IpAddress.new

      if arg.is_a?(Hash) then
        set(arg.dup)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, 4, @ip_address.encode].pack('nna*')
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

load "../../../../test/ospfv2/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0