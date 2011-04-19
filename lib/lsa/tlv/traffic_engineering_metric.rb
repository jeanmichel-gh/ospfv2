=begin rdoc

2.5.5.  Traffic Engineering Metric

The Traffic Engineering Metric sub-TLV specifies the link metric for
traffic engineering purposes.  This metric may be different than the
standard OSPF link metric.  Typically, this metric is assigned by a
network administrator.

The Traffic Engineering Metric sub-TLV is TLV type 5, and is four
octets in length.

=end

require 'lsa/tlv/tlv'

module OSPFv2

  class TrafficEngineeringMetric_Tlv
    include SubTlv
    include Common

    attr_reader :tlv_type, :te_metric

    attr_writer_delegate :ip_address

    def initialize(arg={})
      @tlv_type,  = 5
      @te_metric = 0

      if arg.is_a?(Hash) then
        set(arg.dup)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, 4, @te_metric].pack('nnN')
    end

    def __parse(s)
      @tlv_type, _, @te_metric = s.unpack('nnN')
    end


    def to_s
      self.class.to_s + ": " + te_metric.to_s
    end

    def to_s_junos_style(ident=0)
      "  "*ident + "RtrAddr (1), length #{@length}: #{router_id.to_ip}"
    end

  end
end

load "../../../../test/ospfv2/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

