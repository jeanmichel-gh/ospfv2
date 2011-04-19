=begin rdoc
  
2.5.8.  Unreserved Bandwidth

The Unreserved Bandwidth sub-TLV specifies the amount of bandwidth
not yet reserved at each of the eight priority levels in IEEE
floating point format.  The values correspond to the bandwidth that
can be reserved with a setup priority of 0 through 7, arranged in
increasing order with priority 0 occurring at the start of the sub-
TLV, and priority 7 at the end of the sub-TLV.  The initial values
(before any bandwidth is reserved) are all set to the Unreserved
Reservable Bandwidth.  Each value will be less than or equal to the
Unreserved Reservable Bandwidth.  The units are bytes per second.

The Unreserved Bandwidth sub-TLV is TLV type 8, and is 32 octets in
length.

=end

require 'lsa/tlv/tlv'

module OSPFv2

  class UnreservedBandwidth_Tlv
    include SubTlv
    include Common

    LinkId = Class.new(Id) unless const_defined?(:LinkId)
    attr_reader :tlv_type, :unreserved_bw

    def initialize(arg={})
      @tlv_type = 8
      @unreserved_bw = [0]*8

      if arg.is_a?(Hash) then
        set(arg.dup)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, 32].pack('nn') +
      unreserved_bw.collect { |bw|   bw / 8.0 }.pack('g*')      
    end

    def __parse(s)
      @tlv_type, _, *unreserved_bw = s.unpack('nng*')
      @unreserved_bw = unreserved_bw.collect {|bw| (bw*8).to_i }
    end

    def to_hash
      h=super
      h[:unreserved_bw] = unreserved_bw
      h
    end

    def to_s
      self.class.to_s + ": " + unreserved_bw.collect { |bw| bw }.join(", ")
    end

  end
end

if __FILE__ == $0
  require "test/unit"

  class UnreservedBandwidth_Tlv_Test < Test::Unit::TestCase # :nodoc:
    include OSPFv2
    def test_init
      assert_equal("000800200000000000000000000000000000000000000000000000000000000000000000",
                UnreservedBandwidth_Tlv.new().to_shex)
      assert_equal("OSPFv2::UnreservedBandwidth_Tlv: 0, 0, 0, 0, 0, 0, 0, 0",
                        UnreservedBandwidth_Tlv.new({:unreserved_bw=>[0,0,0,0,0,0,0,0]}).to_s)
      assert_equal([1, 2, 3, 4, 5, 6, 7, 8], 
                UnreservedBandwidth_Tlv.new({:unreserved_bw=>[1, 2, 3, 4, 5, 6, 7, 8]}).to_hash[:unreserved_bw])
      assert_equal("000800203e0000003e8000003ec000003f0000003f2000003f4000003f6000003f800000".split.join,
                UnreservedBandwidth_Tlv.new({:unreserved_bw=>[1, 2, 3, 4, 5, 6, 7, 8]}).to_shex)
    end
  end
  
end
