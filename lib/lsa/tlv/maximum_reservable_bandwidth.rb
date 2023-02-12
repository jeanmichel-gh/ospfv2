#--
# Copyright 2011 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
#++

require_relative 'tlv'

module OSPFv2

  class MaximumReservableBandwidth_Tlv
    include SubTlv
    include Common

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
      "Maximum reservable bandwidth : #{max_resv_bw}"
    end

    def to_s_junos_style(ident=0)
      "  "*ident + "RtrAddr (1), length #{@length}: #{router_id.to_ip}"
    end

  end
end

load File.absolute_path("test/unit/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}") if __FILE__ == $0
