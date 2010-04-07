
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

    def to_s
      super +
      lsas.collect { |x| x.to_s }.join("\n ")
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
        lsas.flatten.compact.each do |lsa|
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
      end
    end

  end
  
end

load "../../test/ospfv2/packet/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__


020500400101010100000000ac4700000000000000000000
00012201c0a801c8c0a801c8800001a700000000
00012202c0a801c8c0a801c88000000100000000

require 'lsa/router'
require 'lsa/summary'
require 'lsa/network'

include OSPFv2



s = "
02 04 05 68 00 01 00 01 00 00 00 00 00 00 00 00 
00 00 00 00 00 00 00 00 00 00 00 0b 00 00 22 01 
00 47 00 0b 00 47 00 0b 80 00 00 01 55 d7 00 84 
00 00 00 09 00 47 00 0b ff ff ff ff 03 00 00 01 
00 46 00 0b 0d 00 44 b6 01 00 00 01 0d 00 44 b4 
ff ff ff fc 03 00 00 01 00 47 00 0a 0d 00 44 ba 
01 00 00 01 0d 00 44 b8 ff ff ff fc 03 00 00 01 
00 47 00 0c 0d 00 44 c1 01 00 00 01
0d 00 44 c0 ff ff ff fc 03 00 00 01 00 48 00 0b
0d 00 45 b1 01 00 00 01 0d 00 45 b0 ff ff ff fc
03 00 00 01 00 00 22 01 00 51 00 03 00 51 00 03
80 00 00 01 9b 76 00 84 00 00 00 09 00 51 00 03
ff ff ff ff 03 00 00 01 00 50 00 03 0d 00 4e 4e
01 00 00 01 0d 00 4e 4c ff ff ff fc 03 00 00 01
00 51 00 02 0d 00 4e 52 01 00 00 01 0d 00 4e 50
ff ff ff fc 03 00 00 01 00 51 00 04 0d 00 4e 59
01 00 00 01 0d 00 4e 58 ff ff ff fc 03 00 00 01
00 52 00 03 0d 00 4f 49 01 00 00 01 0d 00 4f 48
ff ff ff fc 03 00 00 01 00 00 22 01 00 57 00 19
00 57 00 19 80 00 00 01 0f 49 00 84 00 00 00 09
00 57 00 19 ff ff ff ff 03 00 00 01 00 56 00 19
0d 00 54 e6 01 00 00 01 0d 00 54 e4 ff ff ff fc
03 00 00 01 00 57 00 18 0d 00 54 ea 01 00 00 01
0d 00 54 e8 ff ff ff fc 03 00 00 01 00 57 00 1a
0d 00 54 f1 01 00 00 01 0d 00 54 f0 ff ff ff fc
03 00 00 01 00 58 00 19 0d 00 55 e1 01 00 00 01
0d 00 55 e0 ff ff ff fc 03 00 00 01 00 00 22 01
00 44 00 17 00 44 00 17 80 00 00 01 f2 af 00 84
00 00 00 09 00 44 00 17 ff ff ff ff 03 00 00 01
00 43 00 17 0d 00 42 22 01 00 00 01 0d 00 42 20
ff ff ff fc 03 00 00 01 00 44 00 16 0d 00 42 26
01 00 00 01 0d 00 42 24 ff ff ff fc 03 00 00 01
00 44 00 18 0d 00 42 2d 01 00 00 01 0d 00 42 2c
ff ff ff fc 03 00 00 01 00 45 00 17 0d 00 43 1d
01 00 00 01 0d 00 43 1c ff ff ff fc 03 00 00 01
00 00 22 01 00 44 00 1d 00 44 00 1d 80 00 00 01
a7 4f 00 84 00 00 00 09 00 44 00 1d ff ff ff ff
03 00 00 01 00 43 00 1d 0d 00 42 52 01 00 00 01
0d 00 42 50 ff ff ff fc 03 00 00 01 00 44 00 1c
0d 00 42 56 01 00 00 01 0d 00 42 54 ff ff ff fc
03 00 00 01 00 44 00 1e 0d 00 42 5d 01 00 00 01
0d 00 42 5c ff ff ff fc 03 00 00 01 00 45 00 1d
0d 00 43 4d 01 00 00 01 0d 00 43 4c ff ff ff fc
03 00 00 01 00 00 22 01 00 61 00 1f 00 61 00 1f
80 00 00 01 a5 b1 00 84 00 00 00 09 00 61 00 1f
ff ff ff ff 03 00 00 01 00 60 00 1f 0d 00 5e ee
01 00 00 01 0d 00 5e ec ff ff ff fc 03 00 00 01
00 61 00 1e 0d 00 5e f2 01 00 00 01 0d 00 5e f0
ff ff ff fc 03 00 00 01 00 61 00 20 0d 00 5e f9
01 00 00 01 0d 00 5e f8 ff ff ff fc 03 00 00 01
00 62 00 1f 0d 00 5f e9 01 00 00 01 0d 00 5f e8
ff ff ff fc 03 00 00 01 00 00 22 01 00 64 00 20
00 64 00 20 80 00 00 01 eb 0e 00 54 00 00 00 05
00 64 00 20 ff ff ff ff 03 00 00 01 00 63 00 20
0d 00 61 ea 01 00 00 01 0d 00 61 e8 ff ff ff fc
03 00 00 01 00 64 00 1f 0d 00 61 ee 01 00 00 01
0d 00 61 ec ff ff ff fc 03 00 00 01 00 00 22 01
00 18 00 13 00 18 00 13 80 00 00 01 43 8d 00 84
00 00 00 09 00 18 00 13 ff ff ff ff 03 00 00 01
00 17 00 13 0d 00 16 b2 01 00 00 01 0d 00 16 b0
ff ff ff fc 03 00 00 01 00 18 00 12 0d 00 16 b6
01 00 00 01 0d 00 16 b4 ff ff ff fc 03 00 00 01
00 18 00 14 0d 00 16 bd 01 00 00 01 0d 00 16 bc
ff ff ff fc 03 00 00 01 00 19 00 13 0d 00 17 ad
01 00 00 01 0d 00 17 ac ff ff ff fc 03 00 00 01
00 00 22 01 00 4b 00 06 00 4b 00 06 80 00 00 01
6e 67 00 84 00 00 00 09 00 4b 00 06 ff ff ff ff
03 00 00 01 00 4a 00 06 0d 00 48 7e 01 00 00 01
0d 00 48 7c ff ff ff fc 03 00 00 01 00 4b 00 05
0d 00 48 82 01 00 00 01 0d 00 48 80 ff ff ff fc
03 00 00 01 00 4b 00 07 0d 00 48 89 01 00 00 01
0d 00 48 88 ff ff ff fc 03 00 00 01 00 4c 00 06
0d 00 49 79 01 00 00 01 0d 00 49 78 ff ff ff fc
03 00 00 01 00 00 22 01 00 25 00 01 00 25 00 01
80 00 00 01 35 f0 00 6c 00 00 00 07 00 25 00 01
ff ff ff ff 03 00 00 01 00 24 00 01 0d 00 22 f2
01 00 00 01 0d 00 22 f0 ff ff ff fc 03 00 00 01
00 25 00 02 0d 00 22 f9 01 00 00 01 0d 00 22 f8
ff ff ff fc 03 00 00 01 00 26 00 01 0d 00 23 ed
01 00 00 01 0d 00 23 ec ff ff ff fc 03 00 00 01
00 00 22 01 00 64 00 1f 00 64 00 1f 80 00 00 01
f3 d1 00 6c 00 00 00 07 00 64 00 1f ff ff ff ff
03 00 00 01 00 63 00 1f 0d 00 61 e2 01 00 00 01
0d 00 61 e0 ff ff ff fc 03 00 00 01 00 64 00 1e
0d 00 61 e6 01 00 00 01 0d 00 61 e4 ff ff ff fc
03 00 00 01 00 64 00 20 0d 00 61 ed 01 00 00 01
0d 00 61 ec ff ff ff fc 03 00 00 01            
".split.join
# 
# lsu = LinkStateUpdate.new(s.to_a.pack('H*'))
# puts lsu



# # s = '003322010aff08010aff0801800004213d40006c00000007010101010d0d0d01010000010d0d0d00ffffff00030000010aff0801ffffffff030000000aff0804c0a8083101000001c0a80830fffffffc030000010aff0802c0a8082d01000001c0a8082cfffffffc03000001'
# # 
# # puts Lsa.factory([s].pack('H*'))
#   
#   s = "020400e0010101010000000086690000000000000000000000a122010101010101010101800000020000000000a122010101010201010102800000040000000000a122010202020202020202800000020000000000a722010aff08020aff08028000001a00000000009f000218000002010101028000000100000000009f000319000100010101028000000100000000009f000319000200010101028000000100000000009f000319000300010101028000000100000000009f000319000400010101028000000100000000009f000319000500010101028000000100000000".split.join
# 
#   s =              "0204 0088 0aff 0801 0000 0000
#   0x0020:  3fea 0000 0000 0000 0000 0000 0000 0001
#   0x0030:  0033 2201 0aff 0801 0aff 0801 8000 0421
#   0x0040:  3d40 006c 0000 0007 0101 0101 0d0d 0d01
#   0x0050:  0100 0001 0d0d 0d00 ffff ff00 0300 0001
#   0x0060:  0aff 0801 ffff ffff 0300 0000 0aff 0804
#   0x0070:  c0a8 0831 0100 0001 c0a8 0830 ffff fffc
#   0x0080:  0300 0001 0aff 0802 c0a8 082d 0100 0001
#   0x0090:  c0a8 082c ffff fffc 0300 0001
#   ".split.find_all { |n| n =~/^[[:xdigit:]]{4}$/ }.join  
#   ls_update = LinkStateUpdate.new(s.to_a.pack('H*'))
#   p ls_update
#   puts ls_update
# 

__END__


02040088
0aff0801
00000000
3fea0000
00000000
00000000
00000001

003322010aff08010aff0801800004213d40006c00000007010101010d0d0d01010000010d0d0d00ffffff00030000010aff0801ffffffff030000000aff0804c0a8083101000001c0a80830fffffffc030000010aff0802c0a8082d01000001c0a8082cfffffffc03000001

__END__

00000001
00332201
0aff0801
0aff0801
80000421
3d40006c

108


0                   1                   2                   3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|            LS age             |     Options   |       1       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Link State ID                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Advertising Router                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     LS sequence number                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         LS checksum           |             length            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|    0    |V|E|B|        0      |            # links            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Link ID                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Link Data                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|     Type      |     # TOS     |            metric             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                              ...                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|      TOS      |        0      |          TOS  metric          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Link ID                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Link Data                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                              ...                              |


00000007010101010d0d0d01010000010d0d0d00
ffffff00030000010aff
0801ffffffff03000000
0aff0804c0a808310100
0001c0a80830fffffffc
030000010aff0802c0a8
082d01000001c0a8082c
fffffffc03000001

00000001003322010aff08010aff0801800004213d40006c00000007010101010d0d0d01010000010d0d0d00ffffff00030000010aff0801ffffffff030000000aff0804c0a8083101000001c0a80830fffffffc030000010aff0802c0a8082d01000001c0a8082cfffffffc03000001


#
#  Created by Jean-Michel Esnault.
#  Copyright (c) 2008. All rights reserved.
#

require 'lsa_header'
require 'lsa_router'
require 'packet_header'
require 'lsa_ack'


module Ospf

  class LSU
    include Ospf

    attr_reader :lsa, :header
    attr_writer :lsa

    def initialize(arg={})
      @lsa=Array.new
      if arg.is_a?(Hash) then
        arg[:type]=OSPF_LSU
        @header = PacketHeader.new(arg)
        set(arg)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    
    def set(arg)
      return self unless arg.is_a?(Hash)      
      @header.set(arg)
      unless arg[:lsa].nil?
          arg[:lsa].each { |lsa| @lsa << RouterLSA.new(lsa) }
      end
      self
    end
    
    
    def <<(lsa)
      add(lsa)
    end

    
    def add(*_lsa)
      _lsa.flatten.compact.each { |l| @lsa << l if l.is_a?(LSA) }
      self
    end
        

    def enc
      packet = @header.enc
      packet << __enc([[@lsa.size,'N']])
      packet <<  @lsa.collect { |lsa| lsa.enc }.join
      fix_length(packet)
      fix_checksum(packet)  
      packet
    end

    def __parse(s)      
      
      @header = PacketHeader.new(s)
      nlsa = s[24..28].unpack('N')[0]
      lsas = s[28..-1]
      while lsas.size>0
        len = lsas[18..19].unpack('n')[0]
        lsa = lsas.slice!(0,len)
        @lsa << LSA_Factory.create(lsa)
      end
    end
    private :__parse

    
    def to_s
      s = "\nLink State Update:\n  "
      s += @header.to_s
      s += "\n    " unless @lsa == []
      s += @lsa.collect {|lsa| lsa.to_s }.join("\n    ")
      s
    end

    
    def to_hash
      h = @header.to_hash
      h[:lsa] = @lsa.collect { |lsa_h| lsa_h.to_hash }
      h    
    end
    

    def ack(rid)    
      ack = LSA_Ack.new({ :rid => rid, :area => area = @header.area})
      @lsa.each { |l| ack.lsa_headers << l.header  }
      ack
    end    
    

    def each_ls
      @lsa.each { |ls| yield ls }
    end
    

    def keys
      @lsa.collect { |ls| ls.key }
    end
    
  end
  
  def LSU.build(area,rid,*lsa)
    lsus=[]
    len=0
    na = 0
    lsu = Ospf::LSU.new({:area=>area, :rid=>rid}) 
    lsa.flatten.compact.each {|l|
      na +=1
      lsa_len = l.enc.size
      if (len + lsa_len) > (1476-56-20)
        lsus << lsu
        lsu = Ospf::LSU.new({:area=>area, :rid=>rid}) 
        len = 0
      end
      lsu << l
      len += lsa_len
    }
    lsus << lsu
    INFO("Building #{lsus.size} LSUs for sending #{na} LSAs") if lsus.size>1
    lsus
  end  

end


if __FILE__ == $0
  load '../test/lsu_test.rb'
end
