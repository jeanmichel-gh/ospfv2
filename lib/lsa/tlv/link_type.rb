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
  class LinkType_Tlv
    @link_type = { 1=> :p2p, 2=> :multiaccess }
    class << self
      def type_to_s(arg)
        "#{@link_type[arg]}"
      end
    end
    include SubTlv
    include Common
    attr_reader :tlv_type, :link_type
    def initialize(arg={})
      @tlv_type, @link_type = 1,1
      if arg.is_a?(Hash) then
        set(arg.dup)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end
    def encode
      [@tlv_type, 1, @link_type,0,0,0].pack('nnCC3')
    end
    def __parse(s)
      @tlv_type, _, @link_type= s.unpack('nnC')
    end
    def to_s
      "Link Type : #{LinkType_Tlv.type_to_s(link_type)}"
    end
  end
end
