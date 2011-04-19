
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
    include Tlv::Common
    include Common
    
    attr_reader :tlv_type, :_length, :tlvs
    
    def initialize(arg={})
      @tlv_type = 2
      @tlvs = []
      if arg.is_a?(Hash) then
        if arg.has_key?(:tlvs)
          @tlvs = arg[:tlvs].collect { |h| SubTlv.factory(h) }
        end
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
      @tlv_type, @_length, tlvs = s.unpack('nna*')
      while tlvs.size>0
        _, len = tlvs.unpack('nn')
        @tlvs << SubTlv.factory(tlvs.slice!(0,stlv_len(len)))
      end
    end

    def encoded_tlvs
      tlvs.collect { |tlv| tlv.encode }.join
    end
    
    def _length
      encoded_tlvs.size
    end

    def to_s
      self.class.to_s + "(2): " + "\n" + tlvs.collect { |tlv| tlv.to_s }.join("\n")
    end

  end
end

load "../../../../test/ospfv2/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

