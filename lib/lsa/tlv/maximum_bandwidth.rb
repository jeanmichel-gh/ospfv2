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
     attr_reader :tlv_type, :max_bw

     def initialize(arg={})
       @tlv_type = 6
       @max_bw = 0

       if arg.is_a?(Hash) then
         set(arg.dup)
       elsif arg.is_a?(String)
         __parse(arg)
       else
         raise ArgumentError, "Invalid argument", caller
       end
     end

     def encode
       [@tlv_type, 4, @max_bw/8.0].pack('nng')
     end

     def __parse(s)
       @tlv_type, _, max_bw = s.unpack('nng')
       @max_bw = (max_bw * 8).to_int
     end

     def to_s
       self.class.to_s + ": " + max_bw.to_s
     end

     def to_s_junos_style(ident=0)
       "  "*ident + "RtrAddr (1), length #{@length}: #{router_id.to_ip}"
     end

   end
 end

 load "../../../../test/ospfv2/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

