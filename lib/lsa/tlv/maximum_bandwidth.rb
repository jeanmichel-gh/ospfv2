=begin rdoc
  
2.5.6.  Maximum Bandwidth

 The Maximum Bandwidth sub-TLV specifies the maximum bandwidth that
 can be used on this link, in this direction (from the system
 originating the LSA to its neighbor), in IEEE floating point format.
 This is the true link capacity.  The units are bytes per second.

 The Maximum Bandwidth sub-TLV is TLV type 6, and is four octets in
 length.

=end


#FIXME: make bw an IE

 require 'lsa/tlv/tlv'

 module OSPFv2

   class MaximumBandwidth_Tlv
     include SubTlv
     include Common

     LinkId = Class.new(Id) unless const_defined?(:LinkId)
     attr_reader :tlv_type, :length, :max_bw

     def initialize(arg={})
       @tlv_type, @length,  = 6,4
       @max_bw = 0.0

       if arg.is_a?(Hash) then
         set(arg)
       elsif arg.is_a?(String)
         __parse(arg)
       else
         raise ArgumentError, "Invalid argument", caller
       end
     end

     def encode
       [@tlv_type, @length, @max_bw/8.0].pack('nng')
     end

     def __parse(s)
       @tlv_type, _, max_bw = s.unpack('nng')
       @max_bw = max_bw * 8.0
     end

     def to_s
       self.class.to_s + ": " + max_bw.to_s
     end

     def to_s_junos_style(ident=0)
       "  "*ident + "RtrAddr (1), length #{@length}: #{router_id.to_ip}"
     end

   end
 end

 if __FILE__ == $0
   require "test/unit"

   class MaximumBandwidth_SubTLV_Test < Test::Unit::TestCase # :nodoc:
     include OSPFv2
     def test_init
       assert_equal("0006000400000000", MaximumBandwidth_Tlv.new().to_shex)
       assert_equal("OSPFv2::MaximumBandwidth_Tlv: 10000.0", MaximumBandwidth_Tlv.new({:max_bw=>10_000.0}).to_s)
       assert_equal(255, MaximumBandwidth_Tlv.new({:max_bw=>255}).to_hash[:max_bw])
       assert_equal("0006000445ffff00", MaximumBandwidth_Tlv.new({:max_bw=>0xffff}).to_shex)
     end
   end

 end
