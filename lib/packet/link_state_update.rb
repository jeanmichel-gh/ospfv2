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

  A.3.5 The Link State Update packet

      Link State Update packets are OSPF packet type 4.  These packets
      implement the flooding of LSAs.  Each Link State Update packet
      carries a collection of LSAs one hop further from their origin.
      Several LSAs may be included in a single packet.

      Link State Update packets are multicast on those physical networks
      that support multicast/broadcast.  In order to make the flooding
      procedure reliable, flooded LSAs are acknowledged in Link State
      Acknowledgment packets.  If retransmission of certain LSAs is
      necessary, the retransmitted LSAs are always sent directly to the
      neighbor.  For more information on the reliable flooding of LSAs,
      consult Section 13.

          0                   1                   2                   3
          0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
         |   Version #   |       4       |         Packet length         |
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
         |                            # LSAs                             |
         +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
         |                                                               |
         +-                                                            +-+
         |                             LSAs                              |
         +-                                                            +-+
         |                              ...                              |


      # LSAs
          The number of LSAs included in this update.


      The body of the Link State Update packet consists of a list of LSAs.
      Each LSA begins with a common 20 byte header, described in Section
      A.4.1. Detailed formats of the different types of LSAs are described
      in Section A.4.


=end

require 'packet/ospf_packet'
require 'lsa/lsa'
require 'lsa/lsa_factory'
require 'packet/link_state_ack'
module OSPFv2

  class LinkStateUpdate < OspfPacket

    attr_reader :lsas

    def initialize(_arg={})
      arg = _arg.dup
      @lsas=[]
      if arg.is_a?(Hash)
        arg.merge!({:packet_type=>4})
        super arg
      elsif arg.is_a?(String)
        parse arg
      elsif arg.is_a?(self)
        parse arg.encode
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def number_of_lsa
      lsas.size
    end

    def encode
      headers = []
      headers << [lsas.size].pack('N')
      headers << lsas.collect { |x| x.encode }.join
      super headers.join
    end

    def parse(s)
      n, lsas = super(s).unpack('Na*')
      while lsas.size>0
        len = lsas[18..19].unpack('n')[0]
        lsa = lsas.slice!(0,len)
        lsa = Lsa.factory lsa
        if lsa
          @lsas << lsa
        else
          puts "COULD NOT BUILD LSA OUT OF #{lsa.unpack('H*')}"
        end
      end
    end

    def [](val)
      lsas[val]
    end

    # def to_s
    #   s = []
    #   s << super
    #   s << lsas.collect { |x| x.to_s_junos }.join("\n ")
    #   s.join("\n ")
    # end

    def to_s
      s = []
      s << super(:brief)
      s << "\# LSAs #{@lsas.size}"
      s << "Age  Options  Type    Link-State ID   Advr Router     Sequence   Checksum  Length"
      s << @lsas.collect { |x| x.to_s }.join("\n ")
      s.join("\n ")
    end


    def each
      lsas.each { |ls| yield ls }
    end

    def keys
      lsas.collect { |ls| ls.key }
    end

    def ack_lsu(router_id)
      ls_ack = LinkStateAck.new(:router_id => router_id, :area => area = @aread_id)
      each { |lsa| ls_ack.lsa_headers << lsa  }
      ls_ack
    end

    class << self

      def new_lsas(arg={})
        lsus=[]
        len=0
        lsas = arg[:lsas]
        arg.delete(:lsas)
        lsu = new(arg)
        lsas.each do |lsa|
          lsa_len = lsa.encode.size
          if (len + lsa_len) > (1476-56-20)
            lsus << lsu
            lsu = new(arg)
            len = 0
          end
          lsu.lsas << lsa
          len += lsa_len
        end
        lsus << lsu
        lsus
      rescue
        raise
      end
    end

  end

end

load "../../../test/ospfv2/packet/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
