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

  class LinkId_Tlv
    include SubTlv
    include Common

    LinkId = Class.new(Id) unless const_defined?(:LinkId)
    attr_reader :tlv_type, :link_id

    attr_writer_delegate :link_id

    def initialize(arg={})
      @tlv_type  = 2
      @link_id = LinkId.new

      if arg.is_a?(Hash) then
        set(arg.dup)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, 4, @link_id.encode].pack('nna*')
    end

    def __parse(s)
      @tlv_type, _, link_id = s.unpack('nna*')
      @link_id = LinkId.new_ntoh(link_id)
    end


    def to_s
      self.class.to_s + ": " + link_id.to_ip
    end

    def to_s_junos_style(ident=0)
      "  "*ident + "RtrAddr (1), length #{@length}: #{router_id.to_ip}"
    end

  end
end

load "../../../../test/ospfv2/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
