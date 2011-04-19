#--
# Copyright 2011 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
#++

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

