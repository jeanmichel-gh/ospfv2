
=begin rdoc
 2.5.7.  Maximum Reservable Bandwidth

 The Maximum Reservable Bandwidth sub-TLV specifies the maximum
 bandwidth that may be reserved on this link, in this direction, in
 IEEE floating point format.  Note that this may be greater than the
 maximum bandwidth (in which case the link may be oversubscribed).
   This SHOULD be user-configurable; the default value should be the
   Maximum Bandwidth.  The units are bytes per second.

   The Maximum Reservable Bandwidth sub-TLV is TLV type 7, and is four
   octets in length.

=end

require 'lsa/tlv/tlv'

module OSPFv2

  class MaximumReservableBandwidth_Tlv
    include SubTlv
    include Common

    LinkId = Class.new(Id) unless const_defined?(:LinkId)
    attr_reader :tlv_type, :length, :max_resv_bw

    def initialize(arg={})
      @tlv_type, @length,  = 6,4
      @max_resv_bw = 0.0

      if arg.is_a?(Hash) then
        set(arg)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, @length, @max_resv_bw/8.0].pack('nng')
    end

    def __parse(s)
      @tlv_type, _, max_resv_bw = s.unpack('nna*')
      @max_resv_bw = max_resv_bw * 8.0
    end


    def to_s
      self.class.to_s + ": " + max_resv_bw.to_s
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
      assert_equal("0006000400000000", MaximumReservableBandwidth_Tlv.new().to_shex)
      assert_equal("OSPFv2::MaximumReservableBandwidth_Tlv: 10000.0", MaximumReservableBandwidth_Tlv.new({:max_resv_bw=>10_000.0}).to_s)
      assert_equal(255, MaximumReservableBandwidth_Tlv.new({:max_resv_bw=>255}).to_hash[:max_resv_bw])
      assert_equal("0006000445ffff00", MaximumReservableBandwidth_Tlv.new({:max_resv_bw=>0xffff}).to_shex)
    end
  end

end

