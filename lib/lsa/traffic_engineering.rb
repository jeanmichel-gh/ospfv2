#--
# Copyright 2011 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
#++

require 'lsa/opaque'
require 'ie/opaque_id'
require 'ie/opaque_type'
require 'lsa/tlv/tlv_factory'

module OSPFv2
  class TrafficEngineering < Lsa
    include Tlv
    #FIXME: move this under OpaqueId ?????
    @_opaque_id = 0
    class << self
      attr_accessor :_opaque_id
      def opaque_id
        @_opaque_id +=1
      end
      def reset_opaque_id
        @_opaque_id=0
      end
      def new_hash(h)
        r = new(h.dup)
        r
      end
    end

    attr_accessor :top_lvl_tlv

    def initialize(_arg={})
      arg = _arg.dup
      @ls_type = LsType.new(:area)
      case arg
      when Hash
        _arg.delete(:top_lvl_tlv) # or else super will attempt to set to_lvl_tlv
        set arg
      when String
        parse arg
      end
      super
    end

    def set(h)
      return if h.empty?
      if h.has_key?(:top_lvl_tlv)
        tlv = h[:top_lvl_tlv]
        case tlv
        when Hash
          @top_lvl_tlv = OSPFv2::Tlv.factory(tlv)
        when Tlv
          @top_lvl_tlv = tlv
        else
          raise
        end
      end
    end

    def encode
      if top_lvl_tlv
        super top_lvl_tlv.encode
      else
        super
      end
    end

    def to_s
      super +
      top_lvl_tlv.to_s
    rescue => e
      # p top_lvl_tlv
      raise
    end

    def parse(s)
      @top_lvl_tlv = Tlv.factory(super(s))
    end

  end

end

load "../../../test/ospfv2/lsa/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
