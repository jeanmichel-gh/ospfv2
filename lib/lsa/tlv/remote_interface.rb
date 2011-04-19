
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
    attr_reader :tlv_type, :ip_address

    attr_writer_delegate :ip_address

    def initialize(arg={})
      @tlv_type = 4
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
