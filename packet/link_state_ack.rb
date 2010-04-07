
require 'packet/ospf_packet'

module OSPFv2
  
  class LinkStateAck < OspfPacket
    
    attr_accessor :lsa_headers
    
    def self.ack_ls_update(lsu, *args)
      ls_ack = new *args
      ls_ack.lsa_headers = lsu.lsas
      ls_ack
    end
    
    def initialize(_arg={})
      arg = _arg.dup
      @lsa_headers=[]
      if arg.is_a?(Hash)
        arg.merge!({:packet_type=>5})
        super arg
      elsif arg.is_a?(String)
        parse arg
      elsif arg.is_a?(self.class)
        parse arg.encode
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end
    
    def add_lsa_header(lsu)
      lsu.lsas
    end
    
    def encode
      headers = []
      headers << lsa_headers.collect { |x| x.encode.slice(0,20) }.join
      super headers.join
    end
    
    def each_key
      @lsa_headers.each do |lsa|
        yield lsa.key
      end
    end

    def each
      @lsa_headers.each do |lsa|
        yield lsa
      end
    end
    
    def parse(s)
      headers = super(s)
      while headers.size>0
        lsa = Lsa.new headers.slice!(0,20)
        @lsa_headers <<lsa
      end
    end

    def to_s
      super +
      lsa_headers.collect { |x| x.header_to_s }.join("\n ")
    end
  end
  
  
end

load "../../test/ospfv2/packet/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__

<OSPFv2::Router:0x100575610 
@ls_id=#<OSPFv2::Lsa::LsId:0x10053ec50 @id=3232235976>, 
@options=34, @_length=0, 
@sequence_number=#<OSPFv2::SequenceNumber:0x1005429b8 @seqn="k\002\000\200">, 
@ls_age=#<OSPFv2::Lsa::LsAge:0x100543818 @age=1>, 
@_csum=",\353", 
@nwveb=0, 
@time=Sun Mar 21 20:48:57 -0700 2010, 
@advertising_router=#<OSPFv2::Lsa::AdvertisingRouter:0x100541360 @id=3232235976>, 
@links=[#
  <OSPFv2::RouterLink::StubNetwork:0x100537518 @metric=#<OSPFv2::Metric:0x10052d8b0 @metric=1>, @ls_id=#<OSPFv2::RouterLink::LsId:0x100534de0 @id=3338665984>, @router_link_type=#<OSPFv2::RouterLinkType:0x10052ffc0 @router_link_type=3>, @ls_data=#<OSPFv2::RouterLink::LsData:0x1005326f8 @id=4294967040>, @tos_metrics=[]>, #<OSPFv2::RouterLink::TransitNetwork:0x100524d00 @metric=#<OSPFv2::Metric:0x10051b728 @metric=10>, @ls_id=#<OSPFv2::RouterLink::LsId:0x100521f88 @id=3232235976>, @router_link_type=#<OSPFv2::RouterLinkType:0x10051d0a0 @router_link_type=2>, @ls_data=#<OSPFv2::RouterLink::LsData:0x10051f800 @id=3232235976>, @tos_metrics=[]>], 
  @ls_type=#<OSPFv2::LsType:0x1005446f0 @ls_type=1>, @_size="\0000">




 s =               "0204 0088 0aff 0801 0000 0000
 0x0020:  3fea 0000 0000 0000 0000 0000 0000 0001
 0x0030:  0033 2201 0aff 0801 0aff 0801 8000 0421
 0x0040:  3d40 006c 0000 0007 0101 0101 0d0d 0d01
 0x0050:  0100 0001 0d0d 0d00 ffff ff00 0300 0001
 0x0060:  0aff 0801 ffff ffff 0300 0000 0aff 0804
 0x0070:  c0a8 0831 0100 0001 c0a8 0830 ffff fffc
 0x0080:  0300 0001 0aff 0802 c0a8 082d 0100 0001
 0x0090:  c0a8 082c ffff fffc 0300 0001
 ".split.find_all { |n| n =~/^[[:xdigit:]]{4}$/ }.join
 
 p s
 
 ls_ack = LinkStateAck.new(s.to_a.pack('H*'))



__END__

020400880aff0801000000003fea00000000000000000000
00000001003322010aff08010aff080180000421
3d40006c00000007010101010d0d0d0101000001
0d0d0d00ffffff00030000010aff0801ffffffff
030000000aff0804c0a8083101000001c0a80830
fffffffc030000010aff0802c0a8082d01000001c0a8082c

        fffffffc0300000100000001003322010aff0801
        0aff0801800004213d40006c0000000701010101
        0d0d0d01010000010d0d0d00ffffff0003000001
        0aff0801ffffffff030000000aff0804c0a80831
        01000001c0a80830fffffffc030000010aff0802
        c0a8082d01000001c0a8082cfffffffc03000001





ls_ack = LinkStateAck.new

p ls_ack
puts ls_ack

 @r = Router.new
 @n = Network.new
 @a = AsbrSummary.new
 @s = Summary.new
 
 ls_ack.lsa_headers << @r
 ls_ack.lsa_headers << @n
 ls_ack.lsa_headers << @s
 ls_ack.lsa_headers << @a
 # 
 
 ls_ack2 = LinkStateAck.new(ls_ack.encode)

 p ls_ack2
 puts ls_ack2
 ls_ack2.encode
 
 
 

__END__


#
#  Created by Jean-Michel Esnault.
#  Copyright (c) 2008. All rights reserved.
#

=begin rdoc
A.3.6 The Link State Acknowledgment packet

    Link State Acknowledgment Packets are OSPF packet type 5.  To make
    the flooding of LSAs reliable, flooded LSAs are explicitly
    acknowledged.  This acknowledgment is accomplished through the
    sending and receiving of Link State Acknowledgment packets.
    Multiple LSAs can be acknowledged in a single Link State
    Acknowledgment packet.

    Depending on the state of the sending interface and the sender of
    the corresponding Link State Update packet, a Link State
    Acknowledgment packet is sent either to the multicast address
    AllSPFRouters, to the multicast address AllDRouters, or as a
    unicast.  The sending of Link State Acknowledgement packets is
    documented in Section 13.5.  The reception of Link State
    Acknowledgement packets is documented in Section 13.7.

    The format of this packet is similar to that of the Data Description
    packet.  The body of both packets is simply a list of LSA headers.


        0                   1                   2                   3
        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |   Version #   |       5       |         Packet length         |
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
       |                                                               |
       +-                                                             -+
       |                                                               |
       +-                         An LSA Header                       -+
       |                                                               |
       +-                                                             -+
       |                                                               |
       +-                                                             -+
       |                                                               |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                              ...                              |
192.168.1.123
02050040
01010101
00000000
aab50000
00000000
00000000

006a 22 01
c0a801c8
c0a801c8
80000267
00000000
006a2202c0a801c8c0a801c88000000100000000


02050040
01010101
00000000
27b30000
00000000
00000000
00ec 22 01 c0a801c8 c0a801c8 8000026f 561a0014
00ec 22 02 c0a801c8 c0a801c8 80000001 2bb40014


    Each acknowledged LSA is described by its LSA header.  The LSA
    header is documented in Section A.4.1.  It contains all the
    information required to uniquely identify both the LSA and the LSA's
    current instance.
    
    
    LSA Header:
    
    
     0                   1                   2                   3
     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |            LS age             |    Options    |    LS type    |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                        Link State ID                          |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                     Advertising Router                        |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                     LS sequence number                        |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |         LS checksum           |             length            |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  
=end

require 'lsa_header'
require 'packet_header'

module Ospf
class LSA_Ack

  include Ospf
  include Ospf::Ip

  attr_reader :mtu, :lsa_headers, :header
  attr_writer :mtu, :lsa_headers

  def initialize(arg={})
    @lsa_headers=Array.new
    if arg.is_a?(Hash) then
      arg[:type]=OSPF_LSA
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
  end

  def enc
    packet = @header.enc
    packet << lsa_headers.collect {|lsa| lsa.enc }.join
    fix_length(packet)
    fix_checksum(packet)  
    packet
  end

  def __parse(s)      
    @header = PacketHeader.new(s)
    lsas = s[24..-1]
    while lsas.size>0
      @lsa_headers << Ospf::LSA_Header.new(lsas.slice!(0,20))
    end
  end
  private :__parse

  def to_s
    len=LSA_Header.headline.length()      
    s = "\nLink State Acknowledgment packet:\n  "
    s += @header.to_s
    unless @lsa_headers == [] 
      s += "\n  " + LSA_Header.headline + "\n  "
      1.upto(len) { s += "-"}
      s += "\n  "
      s += @lsa_headers.collect {|lsa| lsa.to_s2 }.join("\n  ")
      s += "\n  "
      #1.upto(len) { s += "-"}
      #s += "\n"
    end
    s
  end


  def to_hash
    h=@header.to_hash
    h[:lsa_headers] = @lsa_headers.collect { |lsa_h| lsa_h.to_hash }
    h    
  end

  def each
    @lsa_headers.each { |head|  yield head }
  end

  def keys
    @lsa_headers.collect { |ls| ls.key }
  end

end
end

if __FILE__ == $0
  load '../test/lsa_ack_test.rb'
end
