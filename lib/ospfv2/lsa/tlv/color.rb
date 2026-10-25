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

  class Color_Tlv
    include SubTlv
    include Common

    attr_reader :tlv_type, :color

    def initialize(arg={})
      @tlv_type = 9
      @color = 0

      if arg.is_a?(Hash) then
        set(arg.dup)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, 4, @color].pack('nnN')
    end

    def __parse(s)
      @tlv_type, _, @color = s.unpack('nnN')
    end

    def to_s
      self.class.to_s + ": " + color.to_s
    end

  end
end
