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

  class LocalInterfaceIpAddress_Tlv
    include SubTlv
    include Common

    IpAddress = Class.new(Id) unless const_defined?(:IpAddress)
    attr_reader :tlv_type, :ip_address

    attr_writer_delegate :ip_address

    def initialize(arg={})
      @tlv_type = 3
      @ip_address = IpAddress.new

      if arg.is_a?(Hash) then
        set(arg.dup)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def encode
      [@tlv_type, 4, @ip_address.encode].pack('nna*')
    end

    def __parse(s)
      @tlv_type, _, ip_address = s.unpack('nna*')
      @ip_address = IpAddress.new_ntoh(ip_address)
    end


    def to_s
      "Interface Address : #{ip_address.to_ip}"
    end

    def to_s_junos_style(ident=0)
      "  "*ident + "RtrAddr (1), length #{@length}: #{router_id.to_ip}"
    end

  end
end
