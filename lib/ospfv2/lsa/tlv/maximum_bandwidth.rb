#--
# Copyright 2011 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
#++

#FIXME: make bw an IE

require_relative 'tlv'

module OSPFv2

  class MaximumBandwidth_Tlv
    include SubTlv
    include Common

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
      "Maximum bandwidth : #{max_bw.to_i}"
    end

    def to_s_junos_style(ident=0)
      "  "*ident + "RtrAddr (1), length #{@length}: #{router_id.to_ip}"
    end

  end
end

