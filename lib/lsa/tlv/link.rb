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

  class Link_Tlv
    include Tlv
    include Tlv::Common
    include Common
    
    attr_reader :tlv_type, :_length, :tlvs
    
    def initialize(arg={})
      @tlv_type = 2
      @tlvs = []
      if arg.is_a?(Hash) then
        if arg.has_key?(:tlvs)
          @tlvs = arg[:tlvs].collect { |h| SubTlv.factory(h) }
        end
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end
    
    def has?(klass=nil)
      if klass.nil?
        return tlvs.collect { |tlv| tlv.class }
      else
        return tlvs.find { |tlv| tlv.is_a?(klass) }.nil? ? false : true
      end
    end    

    def find(klass)
      tlvs.find { |a| a.is_a?(klass) }
    end

    def __index(klass)
      i=-1
      tlvs.find { |a| i +=1 ; a.is_a?(klass) }
      i
    end
    private :__index

    def replace(*objs)
      objs.each do |obj|  
        if has?(obj.class)
          index = __index(obj.class)
          tlvs[index]=obj
        else
          add(obj)
        end
      end
      self
    end

    def remove(klass) 
      tlvs.delete_if { |a| a.is_a?(klass) }
    end

    def [](klass)
      find(klass)
    end

    def add(obj)
      if obj.is_a?(OSPFv2::SubTlv)
        @tlvs << obj
      else
        raise
      end
      self
    end
    
    def <<(obj)
      add(obj)
    end

    def encode
      tlvs = encoded_tlvs
      [@tlv_type, tlvs.size, tlvs].pack('nna*')
    end

    def __parse(s)
      @tlv_type, @_length, tlvs = s.unpack('nna*')
      while tlvs.size>0
        _, len = tlvs.unpack('nn')
        @tlvs << SubTlv.factory(tlvs.slice!(0,stlv_len(len)))
      end
    end

    def encoded_tlvs
      tlvs.collect { |tlv| tlv.encode }.join
    end
    
    def _length
      encoded_tlvs.size
    end
    
    def to_s_ios
      #TODO
      tlvs.collect { |tlv| tlv.to_s }.join("\n  ")
    end

    def to_s(args={})
      ident = [' ']* (args[:ident] || 0)
      "Link TLV (#{tlv_type}), length: #{encoded_tlvs.size}" +
      ['',tlvs].flatten.collect { |tlv| tlv.to_s }.join("\n#{ident}")
    end

  end
end

load "../../../../test/ospfv2/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

