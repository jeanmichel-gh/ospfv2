#--
# Copyright 2010 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
# OSPFv2 is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# OSPFv2 is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with OSPFv2.  If not, see <http://www.gnu.org/licenses/>.
#++


=begin rdoc

  
=end

require 'lsa_opaque_header'
require 'lsa_common'

module Ospf

  class TrafficEngineeringLSA < LSA
    include Ospf

    @@_opaque_id={}

    def self.opaque_id(advr)
      if ! @@_opaque_id.has_key?(advr)
        @@_opaque_id[advr] = 0   
      end
      @@_opaque_id[advr] +=1   
    end

    def self.create(rid, *tlvs)
      te = new({:advr=>rid, :opaque_id=> self.opaque_id(rid),})
      tlvs.each { |tlv| te << tlv }
      te
    end

    attr_reader :tlvs, :header
    attr_writer :tlvs

    def initialize(arg={})
      @tlvs=Array.new
      if arg.is_a?(Hash) then
        arg[:lstype] ||=10
        #arg[:lstype]=10 if arg[:lstype].nil?
        arg[:opaque_id]=1 if arg[:opaque_id].nil?
        arg[:opaque_type]=1 if arg[:opaque_type].nil?
        @header = OpaqueLSA_Header.new(arg)
        set(arg)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end
    
    def append(tlv)
      if tlv.is_a?(TLV)
        @tlvs << tlv
      end
      self
    end
    
    def <<(tlv)
      append(tlv)
    end
    
    def set(arg)
      return self unless arg.is_a?(Hash)
      @header.set(arg)
      unless arg[:tlvs].nil?
        arg[:tlvs].each { |tlv| 
          tlv.is_a?(TLV) ? @tlvs << tlv : @tlvs << TLV_Factory.new(tlv) 
        }
      end
      self
    end
    
    def enc
      packet  = @header.enc
      packet <<  @tlvs.collect { |tlv| tlv.enc }.join
      packet_size(packet,@header)
      packet_fletchsum(packet)
    end

    def __parse(s)
      @header = OpaqueLSA_Header.new(s)
      tlvs = s[20..-1]
      while tlvs.size>0
        len = tlvs[2..3].unpack('n')[0]
        @tlvs << SubTLV_Factory.create(tlvs.slice!(0,__stlv_len(len)))
      end
    end
    private :__parse
    
    def to_s
      enc
      s = @header.to_s
      s += @tlvs.collect {|tlv| "\n#{tlv.to_s}" }.join
      s
    end
    
    def to_s_junos_style(rtype='')
      enc
      case @header.lstype
      when 9 ; slstype = 'link-local' ; scope='OpaqLoca'
      when 10 ; slstype = 'Area' ; scope="OpaqArea" 
      when 11 ; slstype = 'AS' ; scope="OpaqAS" 
      else ; slstype = 'Unknown type #{@header.lstype}(should be 9,10, or 11)'
      end
      s = @header.to_s_junos_style(scope,rtype)
      case @header.opaque_type
      when 1 ; soid = 'TE'
      else ; soid = "Unknown Opaque '#{@header.opaque_type}'"
      end
      s += "\n  #{slstype} #{soid} LSA type"
      s += @tlvs.collect {|tlv| "\n#{tlv.to_s_junos_style(1)}" }.join
      s
    end
      
    def to_hash
      enc
      h = @header.to_hash
      h[:tlvs] = @tlvs.collect { |tlv| tlv.to_hash }
      h    
    end
  end

end


if __FILE__ == $0
  load '../test/lsa_traffic_engineering_test.rb'
end
