
=begin rdoc

 2.4.2.  Link TLV

 The Link TLV describes a single link.  It is constructed of a set of
 sub-TLVs.  There are no ordering requirements for the sub-TLVs.

 Only one Link TLV shall be carried in each LSA, allowing for fine
 granularity changes in topology.

 The Link TLV is type 2, and the length is variable.

 The following sub-TLVs of the Link TLV are defined:

 1 - Link type (1 octet)
 2 - Link ID (4 octets)
 3 - Local interface IP address (4 octets)
 4 - Remote interface IP address (4 octets)
 5 - Traffic engineering metric (4 octets)
 6 - Maximum bandwidth (4 octets)
 7 - Maximum reservable bandwidth (4 octets)
 8 - Unreserved bandwidth (32 octets)
 9 - Administrative group (4 octets)

 This memo defines sub-Types 1 through 9.  See the IANA Considerations
 section for allocation of new sub-Types.

 The Link Type and Link ID sub-TLVs are mandatory, i.e., must appear
 exactly once.

 All other sub-TLVs defined here may occur at most
 once.  These restrictions need not apply to future sub-TLVs.
 Unrecognized sub-TLVs are ignored.

 Various values below use the (32 bit) IEEE Floating Point format.
 For quick reference, this format is as follows:

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |S|    Exponent   |                  Fraction                   |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

 S is the sign, Exponent is the exponent base 2 in "excess 127"
 notation, and Fraction is the mantissa - 1, with an implied binary
 point in front of it.  Thus, the above represents the value:

 (-1)**(S) * 2**(Exponent-127) * (1 + Fraction)

 For more details, refer to [4].

=end

require 'lsa/tlv/tlv'

module OSPFv2

  class Link_Tlv
    include Tlv
    include Common
    
    attr_reader :tlv_type, :length, :tlvs
    
    def initialize(arg={})
      @tlv_type = 1
      @tlvs = []
      if arg.is_a?(Hash) then
        set(arg)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def has?(klass=nil)
      if klass.nil?
        return tlvs.collect { |tlv| tlv.class }
      else
        return tlvs.find { |tlv| tlv.is_a?(klass) }.nil? ? false : true
      end
    end    

    def find(klass)
      tlvs.find { |a| a.is_a?(klass) }
    end

    def __index(klass)
      i=-1
      tlvs.find { |a| i +=1 ; a.is_a?(klass) }
      i
    end
    private :__index

    def replace(*objs)
      objs.each do |obj|  
        if has?(obj.class)
          index = __index(obj.class)
          tlvs[index]=obj
        else
          add(obj)
        end
      end
      self
    end

    def remove(klass) 
      tlvs.delete_if { |a| a.is_a?(klass) }
    end

    def [](klass)
      find(klass)
    end

    def add(obj)
      if obj.is_a?(OSPFv2::SubTlv)
        @tlvs << obj
      else
        raise
      end
      self
    end
    
    def <<(obj)
      add(obj)
    end

    def encode
      tlvs = encoded_tlvs
      [@tlv_type, tlvs.size, tlvs].pack('nna*')
    end

    def __parse(s)
    end

    def encoded_tlvs
      tlvs.collect { |tlv| tlv.encode }.join
    end
    
    def length
      encoded_tlvs.size
    end

    def to_s
      self.class.to_s + "(2): " + "\n" + tlvs.collect { |tlv| tlv.to_s }.join("\n")
    end

  end
end


if __FILE__ == $0
  require "test/unit"

  require 'lsa/tlv/link_type_tlv'
  require 'lsa/tlv/link_id_tlv'

  class Link_Tlv_Test < Test::Unit::TestCase # :nodoc:
    include OSPFv2
    def test_init
      
      l = Link_Tlv.new
      p l
      
      l << (link_type = LinkType_Tlv.new)
      p l
      
      p l.to_shex
      p l.length
      
      
      l << (link_id = LinkId_Tlv.new(:link_id=>'1.2.3.4'))
      p l
      
      p l.to_shex
      p l.length
      puts l
      
      
    end
  end

end



__END__



def setup
  @link_tlv = LinkTLV.new()    
  link_type = LinkTypeSubTLV.new({:link_type=>1})
  link_id = LinkID_SubTLV.new({:link_id=>'12.1.1.1'})
  local_if_addr = LocalInterfaceIP_Address_SubTLV.new({:local_interface_ip_address => '192.168.208.86', })
  rmt_if_addr = RemoteInterfaceIP_Address_SubTLV.new({:remote_interface_ip_address =>  '192.168.208.87', })
  te_metric = TE_MetricSubTLV.new({:te_metric => 1, })
  max_bw = MaximumBandwidth_SubTLV.new({:max_bw => 155.52*1000000, })
  max_resv_bw = MaximumReservableBandwidth_SubTLV.new({:max_resv_bw => 155.52*1000000, })
  unresv_bw = UnreservedBandwidth_SubTLV.new({:unreserved_bw => [155.52*1000000]*8, })
  @link_tlv << link_type << link_id << local_if_addr << rmt_if_addr << te_metric << max_bw << max_resv_bw << unresv_bw
  @te_lsa = TrafficEngineeringLSA.new({:advr=>'0.1.0.1',})  # default to area lstype 10
  @te_lsa << @link_tlv
end

def test_init
  link_type = SubTLV_Factory.create({:tlv_type=>1, :link_type=>1})
  link_id = SubTLV_Factory.create({:tlv_type=>2, :link_id=>"1.1.1.1"})
  #             type len  type len  va filler type len  value
  assert_equal("0002 0010 0001 0001 01 000000 0002 0004 01010101".split.join, 
  (LinkTLV.new() << link_type << link_id).to_shex)
  link_type = SubTLV_Factory.create({:tlv_type=>1, :link_type=>1})
  link_id = SubTLV_Factory.create({:tlv_type=>2, :link_id=>"1.1.1.1"})
  rmt_ip = RemoteInterfaceIP_Address_SubTLV.new({:remote_interface_ip_address=>"1.1.1.1"})
  l = LinkTLV.new() 
  l << link_type
  l << link_id
  l = LinkTLV.new() << link_type << link_id << rmt_ip
  l.to_shex
  l.to_hash
  l1  = LinkTLV.new(l.enc)
  assert_equal(1,l1.tlvs[0].to_hash[:link_type])
  assert_equal(l1.to_shex, l.to_shex)
end




=begin rdoc

 2.4.2.  Link TLV

 The Link TLV describes a single link.  It is constructed of a set of
 sub-TLVs.  There are no ordering requirements for the sub-TLVs.

 Only one Link TLV shall be carried in each LSA, allowing for fine
 granularity changes in topology.

 The Link TLV is type 2, and the length is variable.

 The following sub-TLVs of the Link TLV are defined:

 1 - Link type (1 octet)
 2 - Link ID (4 octets)
 3 - Local interface IP address (4 octets)
 4 - Remote interface IP address (4 octets)
 5 - Traffic engineering metric (4 octets)
 6 - Maximum bandwidth (4 octets)
 7 - Maximum reservable bandwidth (4 octets)
 8 - Unreserved bandwidth (32 octets)
 9 - Administrative group (4 octets)

 This memo defines sub-Types 1 through 9.  See the IANA Considerations
 section for allocation of new sub-Types.

 The Link Type and Link ID sub-TLVs are mandatory, i.e., must appear
 exactly once.

 All other sub-TLVs defined here may occur at most
 once.  These restrictions need not apply to future sub-TLVs.
 Unrecognized sub-TLVs are ignored.

 Various values below use the (32 bit) IEEE Floating Point format.
 For quick reference, this format is as follows:

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |S|    Exponent   |                  Fraction                   |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

 S is the sign, Exponent is the exponent base 2 in "excess 127"
 notation, and Fraction is the mantissa - 1, with an implied binary
 point in front of it.  Thus, the above represents the value:

 (-1)**(S) * 2**(Exponent-127) * (1 + Fraction)

 For more details, refer to [4].

 =end

 class LinkTLV < TLV
   include Ospf

   attr_reader :tlv_type, :length, :tlvs

   def initialize(arg={})
     @tlv_type, @length, @tlvs = 2, 0, []
     if arg.is_a?(Hash) then
       set(arg)
     elsif arg.is_a?(String)
       __parse(arg)
     else
       raise ArgumentError, "Invalid argument", caller
     end
     self
   end

   def add(tlv)
     if tlv.is_a?(Ospf::SubTLV)
       @tlvs << tlv
     end
     self
   end

   def <<(tlv)
     add(tlv)
   end

   def set(arg)
     return self unless arg.is_a?(Hash)
     unless arg[:tlvs].nil?
       arg[:tlvs].each { |tlv| 
         tlv.is_a?(SubTLV) ? @tlvs << tlv : @tlvs << SubTLV.new(tlv) 
       }
     end
     self
   end

   def enc
     _tlvs =  @tlvs.collect { |tlv| tlv.enc }.join
     @length = _tlvs.size
     s = __enc([
       [@tlv_type,  'n'], 
       [@length, 'n'], 
       ])
       s += _tlvs
       s
     end

     def __parse(s)
       arr = s.unpack('nn')
       @tlv_type = arr[0]
       @length= arr[1]
       tlvs = s[4..-1]
       while tlvs.size>0
         len = tlvs[2..3].unpack('n')[0]
         @tlvs << SubTLV_Factory.create(tlvs.slice!(0,__stlv_len(len)))
       end
     end
     private :__parse

     def to_hash
       {
         :tlv_type => tlv_type,
         :tlvs => @tlvs.collect { |tlv| tlv.to_hash }
       }
     end

     def to_s
       @length =  @tlvs.collect { |tlv| tlv.enc }.join.size
       self.class.to_s + "(2): " + "\n" +
       @tlvs.collect { |tlv| tlv.to_s }.join("\n")
     end

     def to_s_junos_style(ident=0)
       s = "  "* ident + "Link (2), length #{@length}:\n"
       s += @tlvs.collect { |tlv| tlv.to_s_junos_style(ident+1) }.join("\n")
     end

     def self.create(args={})
       link_tlv = LinkTLV.new()   
       link_type, link_id, local_if_addr, rmt_if_addr, te_metric, max_bw, max_resv_bw = nil, nil, nil, nil, nil, nil, nil    
       link_type = LinkTypeSubTLV.new(args) if args.has_key?(:link_type)
       link_id = LinkID_SubTLV.new(args) if args.has_key?(:link_id)
       local_if_addr = LocalInterfaceIP_Address_SubTLV.new(args) if args.has_key?(:local_interface_ip_address)
       rmt_if_addr = RemoteInterfaceIP_Address_SubTLV.new(args) if args.has_key?(:remote_interface_ip_address)
       te_metric = TE_MetricSubTLV.new(args) if args.has_key?(:te_metric)
       max_bw = MaximumBandwidth_SubTLV.new(args) if args.has_key?(:max_bw)
       max_resv_bw = MaximumReservableBandwidth_SubTLV.new(args) if args.has_key?(:max_resv_bw)
       unresv_bw = UnreservedBandwidth_SubTLV.new(args) if args.has_key?(:unreserved_bw)
       [link_type, link_id, local_if_addr, rmt_if_addr, te_metric, max_bw, max_resv_bw, unresv_bw].each do |sub_tlv|
         link_tlv << sub_tlv unless sub_tlv.nil?
       end
       link_tlv    
     end

     def has?(klass=nil)
       if klass.nil?
         return tlvs.collect { |tlv| tlv.class }
       else
         return tlvs.find { |tlv| tlv.is_a?(klass) }.nil? ? false : true
       end
     end    

     def find(klass)
       tlvs.find { |a| a.is_a?(klass) }
     end

     def __index(klass)
       i=-1
       tlvs.find { |a| i +=1 ; a.is_a?(klass) }
       i
     end
     private :__index

     def replace(*objs)
       objs.each do |obj|  
         if has?(obj.class)
           index = __index(obj.class)
           tlvs[index]=obj
         else
           add(obj)
         end
       end
       self
     end

     def remove(klass) 
       tlvs.delete_if { |a| a.is_a?(klass) }
     end

     def [](klass)
       find(klass)
     end

   end
