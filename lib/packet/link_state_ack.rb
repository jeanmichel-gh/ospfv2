# A.3.6 The Link State Acknowledgment packet
# 
#     Link State Acknowledgment Packets are OSPF packet type 5.  To make
#     the flooding of LSAs reliable, flooded LSAs are explicitly
#     acknowledged.  This acknowledgment is accomplished through the
#     sending and receiving of Link State Acknowledgment packets.
#     Multiple LSAs can be acknowledged in a single Link State
#     Acknowledgment packet.
# 
#     Depending on the state of the sending interface and the sender of
#     the corresponding Link State Update packet, a Link State
#     Acknowledgment packet is sent either to the multicast address
#     AllSPFRouters, to the multicast address AllDRouters, or as a
#     unicast.  The sending of Link State Acknowledgement packets is
#     documented in Section 13.5.  The reception of Link State
#     Acknowledgement packets is documented in Section 13.7.
# 
#     The format of this packet is similar to that of the Data Description
#     packet.  The body of both packets is simply a list of LSA headers.
# 
# 
#         0                   1                   2                   3
#         0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |   Version #   |       5       |         Packet length         |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |                          Router ID                            |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |                           Area ID                             |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |           Checksum            |             AuType            |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |                       Authentication                          |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |                       Authentication                          |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |                                                               |
#        +-                                                             -+
#        |                                                               |
#        +-                         An LSA Header                       -+
#        |                                                               |
#        +-                                                             -+
#        |                                                               |
#        +-                                                             -+
#        |                                                               |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |                              ...                              |
#        
#        
       
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
      s =[]
      s << super
      s << "Age  Options  Type    Link-State ID   Advr Router     Sequence   Checksum  Length" if lsa_headers.size>0
      s << lsa_headers.collect { |x| x.to_s_dd }
      s.join("\n ")
    end
  end

end

load "../../../test/ospfv2/packet/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

