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

http://www.ietf.org/rfc/rfc2328.txt

A.3.1 The OSPF packet header

    Every OSPF packet starts with a standard 24 byte header.  This
    header contains all the information necessary to determine whether
    the packet should be accepted for further processing.  This
    determination is described in Section 8.2 of the specification.


        0                   1                   2                   3
        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |   Version #   |     Type      |         Packet length         |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                          Router ID                            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                           Area ID                             |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |           Checksum            |             AuType            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                       Authentication                          |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                       Authentication                          |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+


    Version #
        The OSPF version number.  This specification documents version 2
        of the protocol.

    Type
        The OSPF packet types are as follows. See Sections A.3.2 through
        A.3.6 for details.


                          Type   Description
                          ________________________________
                          1      Hello
                          2      Database Description
                          3      Link State Request
                          4      Link State Update
                          5      Link State Acknowledgment




    Packet length
        The length of the OSPF protocol packet in bytes.  This length
        includes the standard OSPF header.

    Router ID
        The Router ID of the packet's source.

    Area ID
        A 32 bit number identifying the area that this packet belongs
        to.  All OSPF packets are associated with a single area.  Most
        travel a single hop only.  Packets travelling over a virtual
        link are labelled with the backbone Area ID of 0.0.0.0.

    Checksum
        The standard IP checksum of the entire contents of the packet,
        starting with the OSPF packet header but excluding the 64-bit
        authentication field.  This checksum is calculated as the 16-bit
        one's complement of the one's complement sum of all the 16-bit
        words in the packet, excepting the authentication field.  If the
        packet's length is not an integral number of 16-bit words, the
        packet is padded with a byte of zero before checksumming.  The
        checksum is considered to be part of the packet authentication
        procedure; for some authentication types the checksum
        calculation is omitted.

    AuType
        Identifies the authentication procedure to be used for the
        packet.  Authentication is discussed in Appendix D of the
        specification.  Consult Appendix D for a list of the currently
        defined authentication types.


    Authentication
        A 64-bit field for use by the authentication scheme. See
        Appendix D for details.

=end


require 'infra/ospf_common'
require 'ie/id'
require 'ie/ospf_version'
require 'ie/packet_type'
require 'ie/au_type'

module OSPFv2
  
  RouterId = Class.new(Id)
  AreaId   = Class.new(Id)
  
  class OspfPacket
    include OSPFv2
    include OSPFv2::Common
    
    attr_reader :area_id, :router_id, :version, :ospf_version, :packet_type, :au_type
    attr_writer_delegate :area_id, :router_id, :packet_type, :au_type
    
    def packet_name
      self.class.to_s.split('::').last.to_underscore
    end
    alias :name :packet_name
    
    def initialize(arg={})
      
      if arg.is_a?(Hash)
        @ospf_version = OspfVersion.new
        @packet_type = PacketType.new
        @area_id = AreaId.new
        @router_id = RouterId.new
        @au_type = AuType.new
        @authentication=''
        set(arg)
      elsif arg.is_a?(String)
        parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
      @_len=nil
    end
    
    def encode(payload='',router_id=@router_id)
      @_len = 24 + payload.size
      packet = @ospf_version.encode
      packet << @packet_type.encode
      packet << [24 + payload.size].pack('n')
      packet << router_id.encode
      packet << area_id.encode
      packet << [0].pack('n')
      packet << @au_type.encode
      packet << [''].pack('a8')
      packet << payload
      packet[12..13]= self.csum = [checksum(packet)].pack('n')
      packet
    end

  # Version 2, RouterId 0.0.0.1, AreaId 0.0.0.0, AuType 0, Checksum 0x9580, len 9999

    def to_s_brief
      encode
      "Version #{ospf_version.to_i}, RouterId #{router_id.to_ip}, AreaId #{area_id.to_ip}, Checksum #{0}, len #{@_len}"
    end
  
    def to_s_default(verbosity=:brief)
      case verbosity
      when :brief
        to_s_brief
      else
        s=[]
        s << self.class.to_s.split('::').last + ":"
        s << ospf_version.to_s
        s << packet_type.to_s
        s << router_id.to_s
        s << area_id.to_s
        s << au_type.to_s
        s << [@authentication].pack('a8')
        s.join("\n ")
      end
    end

    alias :to_s_junos :to_s_default 
    alias :to_s_junos_verbose :to_s_junos

    def to_s(*args)
      return to_s_default(*args) unless defined?($style)
      case $style
      when :junos ; to_s_junos(*args)
      when :junos_verbose ; to_s_junos_verbose(*args)
      else
        to_s_default(*args)
      end
    end

    def method_missing(method, *args, &block)
      if method == :to_s_junos
        to_s_default(*args)
      else
        super
      end
    end

    def to_hash(verbose=false)
      encode
      h = super()
      h.delete(:authentication) if @authentication==''
      h.delete(:csum) unless verbose
      h
    end
    
    private
    
    def csum=(value)
      raise if value.is_a?(Fixnum)
      @_csum=value
    end
    
    def parse(s)
      v, pt, len, rid, aid, csum, au_type, _, _, packet = s.unpack('CCnNNnnNNa*')
      @ospf_version = OspfVersion.new(v)
      @packet_type = PacketType.new(pt)
      @router_id = RouterId.new(rid)
      @area_id = AreaId.new(aid)
      @au_type = AuType.new(au_type)
      @_packet_len = len
      packet
    end
    
    def checksum(data)
      data += "\000" if data.length % 2 >0
      s = 0
      data.unpack("n*").each { |x|
        s += x
        if s > 0xffff
          carry = s >> 16
          s &= 0xffff
          s += carry
        end
      }
      ((s >> 16) + (s & 0xffff)) ^ 0xffff
    end
  end
  
  require 'packet/hello'
  require 'packet/database_description'
  require 'packet/link_state_update'
  require 'packet/link_state_request'
  
  class OspfPacket
    include OSPFv2
    include OSPFv2::Common
    
    HELLO = 1
    DATABASE_DESCRIPTION = 2
    LINK_STATE_REQUEST = 3
    LINK_STATE_UPDATE = 4
    LINK_STATE_ACKNOWLEDGMENT = 5
    
    class << self
      
      def factory(arg)

        if arg.is_a?(String)
          s = arg.dup
          version, type, len = s.unpack('CCn')

          raise RuntimeError, "Bogus OSPF Version #{version}" unless version==2
          case type
          when HELLO                     ; Hello.new(s)
          when DATABASE_DESCRIPTION      ; DatabaseDescription.new(s)
          when LINK_STATE_REQUEST        ; LinkStateRequest.new(s)
          when LINK_STATE_UPDATE         ; LinkStateUpdate.new(s)
          when LINK_STATE_ACKNOWLEDGMENT ; LinkStateAck.new(s)
          else
            raise RuntimeError, "unknown OSPFv2 packet type #{type}"
          end
          
        elsif arg.is_a?(Hash)
          case arg[:packet_type]
          when :hello     ; Hello.new(arg)
          when :dd        ; DatabaseDescription.new(arg)
          else
            raise RuntimeError, "Cannot yet build this packet from hash #{arg[:packet_type]}"
          end
        end

      end
      
    end
    
  end
  
end

load "../../../test/ospfv2/packet/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
