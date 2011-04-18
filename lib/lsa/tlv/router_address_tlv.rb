
=begin rdoc
2.4.1.  Router Address TLV

The Router Address TLV specifies a stable IP address of the
advertising router that is always reachable if there is any
connectivity to it; this is typically implemented as a "loopback
address".  The key attribute is that the address does not become
unusable if an interface is down.  In other protocols, this is known
as the "router ID," but for obvious reasons this nomenclature is
avoided here.  If a router advertises BGP routes with the BGP next
hop attribute set to the BGP router ID, then the Router Address
SHOULD be the same as the BGP router ID.

If IS-IS is also active in the domain, this address can also be used
to compute the mapping between the OSPF and IS-IS topologies.  For
example, suppose a router R is advertising both IS-IS and OSPF
Traffic Engineering LSAs, and suppose further that some router S is
building a single Traffic Engineering Database (TED) based on both
IS-IS and OSPF TE information.  R may then appear as two separate
nodes in S's TED.  However, if both the IS-IS and OSPF LSAs generated
by R contain the same Router Address, then S can determine that the
IS-IS TE LSA and the OSPF TE LSA from R are indeed from a single
router.

The router address TLV is type 1, has a length of 4, and a value that
is the four octet IP address.  It must appear in exactly one Traffic
Engineering LSA originated by a router.

=end  

require 'lsa/tlv/tlv'

module OSPFv2
  

  class RouterAddress_Tlv
    include SubTlv
    include Common
    
    RouterId = Class.new(Id) unless const_defined?(:RouterId)
    attr_reader :tlv_type, :length, :router_id
    
    attr_writer_delegate :router_id

    def initialize(arg={})
      @tlv_type, @length,  = 1,4
      @router_id = RouterId.new

      if arg.is_a?(Hash) then
        set(arg)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, @length, @router_id.encode].pack('nna*')
    end

    def __parse(s)
      @tlv_type, _, router_id = s.unpack('nna*')
      @router_id = RouterId.new_ntoh(router_id)
    end


    def to_s
      "RouterID TLV: #{router_id.to_ip}"
    end

    def to_s_junos_style(ident=0)
      "  "*ident + "RtrAddr (1), length #{@length}: #{router_id.to_ip}"
    end

  end
end

if __FILE__ == $0
  require "test/unit"
  # require "tlv/tlv"
  class RouterAddress_TlvTlv_Test < Test::Unit::TestCase # :nodoc:
    include OSPFv2
    def test_init
      assert_equal("0001000400000000", RouterAddress_Tlv.new().to_shex)
      assert_equal("RouterID TLV: 1.1.1.1", RouterAddress_Tlv.new(:router_id=>"1.1.1.1").to_s)
      assert_equal("1.1.1.1", RouterAddress_Tlv.new(:router_id=>"1.1.1.1").to_hash[:router_id])
      assert_equal("0001000401010101", RouterAddress_Tlv.new(:router_id=>"1.1.1.1").to_shex)
      assert_equal("0001000401010101", RouterAddress_Tlv.new(RouterAddress_Tlv.new(:router_id=>"1.1.1.1").encode).to_shex)
      assert_equal(true, RouterAddress_Tlv.new(:router_id=>"1.1.1.1").is_a?(Tlv))
      assert_equal(1, RouterAddress_Tlv.new(:router_id=>"1.1.1.1").tlv_type)
    end
  end
end
