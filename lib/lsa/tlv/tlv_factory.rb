#--
# Copyright 2011 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
#++

require 'lsa/tlv/router_address'
require 'lsa/Tlv/link_type'

module OSPFv2::Tlv
  def self.factory(arg={})
    type=0
    case arg
    when Hash
      return nil unless arg.has_key?(:tlv_type)
      type = arg[:tlv_type]
    when String
      type = arg.unpack('n')[0]
      return nil unless type
    else
      raise
    end
    case type
    when 1 ; OSPFv2::RouterAddress_Tlv.new(arg.dup)
    when 2 ; OSPFv2::Link_Tlv.new(arg.dup)
    else
      raise
    end
  end
end

require 'lsa/tlv/link'
require 'lsa/tlv/link_type'
require 'lsa/tlv/link_id'
require 'lsa/tlv/local_interface'
require 'lsa/tlv/remote_interface'
require 'lsa/tlv/maximum_bandwidth'
require 'lsa/tlv/maximum_reservable_bandwidth'
require 'lsa/tlv/unreserved_bandwidth'
require 'lsa/tlv/traffic_engineering_metric'

module OSPFv2::SubTlv
  def self.factory(arg={})
    if arg.is_a?(Hash)
      return nil if arg[:tlv_type].nil?
      type = arg[:tlv_type]
    elsif arg.is_a?(String)
      type = arg.unpack('n')[0]
    else
      return
    end
    case type
    when 1 ; OSPFv2::LinkType_Tlv.new(arg)
    when 2 ; OSPFv2::LinkId_Tlv.new(arg)
    when 3 ; OSPFv2::LocalInterfaceIpAddress_Tlv.new(arg)
    when 4 ; OSPFv2::RemoteInterfaceIpAddress_Tlv.new(arg)
    when 5 ; OSPFv2::TrafficEngineeringMetric_Tlv.new(arg)
    when 6 ; OSPFv2::MaximumBandwidth_Tlv.new(arg)
    when 7 ; OSPFv2::MaximumReservableBandwidth_Tlv.new(arg)
    when 8 ; OSPFv2::UnreservedBandwidth_Tlv.new(arg)
    when 9 ; OSPFv2::Color_Tlv.new(arg)
    else
      raise
    end
  end
end

load "../../../../test/ospfv2/lsa/tlv/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

