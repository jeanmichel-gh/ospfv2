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

  class UnreservedBandwidth_Tlv
    include SubTlv
    include Common

    LinkId = Class.new(Id) unless const_defined?(:LinkId)
    attr_reader :tlv_type, :unreserved_bw

    def initialize(arg={})
      @tlv_type = 8
      @unreserved_bw = [0]*8

      if arg.is_a?(Hash) then
        set(arg.dup)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, 32].pack('nn') +
      unreserved_bw.collect { |bw|   bw / 8.0 }.pack('g*')      
    end

    def __parse(s)
      @tlv_type, _, *unreserved_bw = s.unpack('nng*')
      @unreserved_bw = unreserved_bw.collect {|bw| (bw*8).to_i }
    end

    def to_hash
      h=super
      h[:unreserved_bw] = unreserved_bw
      h
    end
    def to_s
      "Unreserved bandwidth : " + unreserved_bw.collect { |bw| "%s" % bw }.join(", ")
    end

  end
end

