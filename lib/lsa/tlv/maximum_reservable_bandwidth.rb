
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
    attr_reader :tlv_type, :max_resv_bw

    def initialize(arg={})
      @tlv_type, = 7
      @max_resv_bw = 0

      if arg.is_a?(Hash) then
        set(arg.dup)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, 4, @max_resv_bw/8.0].pack('nng')
    end

    def __parse(s)
      @tlv_type, _, max_resv_bw = s.unpack('nng')
      @max_resv_bw = (max_resv_bw*8).to_int
    end


    def to_s
      self.class.to_s + ": " + max_resv_bw.to_s
    end

    def to_s_junos_style(ident=0)
      "  "*ident + "RtrAddr (1), length #{@length}: #{router_id.to_ip}"
    end

  end
end

load "../../../../test/ospfv2/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
