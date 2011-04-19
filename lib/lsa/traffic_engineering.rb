#
#  Created by Jean-Michel Esnault.
#  Copyright (c) 2008. All rights reserved.
#

=begin rdoc

 one top level tlv
 either router_address or link
 
=end

require 'lsa/opaque'
require 'ie/opaque_id'
require 'ie/opaque_type'
require 'lsa/tlv/tlv_factory'

module OSPFv2
  class TrafficEngineering < Lsa
    include Tlv
    #FIXME: move this under OpaqueId ?????
    @_opaque_id = 0
    class << self
      attr_accessor :_opaque_id
      def opaque_id
        @_opaque_id +=1
      end
      def reset_opaque_id
        @_opaque_id=0
      end
      def new_hash(h)
        r = new(h.dup)
        r
      end
    end
    
    attr_accessor :top_lvl_tlv

    def initialize(_arg={})
      arg = _arg.dup
      @ls_type = LsType.new(:area)
      case arg
      when Hash
        _arg.delete(:top_lvl_tlv) # or else super will attempt to set to_lvl_tlv
          set arg
      when String
        parse arg
      end
      super
    end

    def set(h)
      return if h.empty?
      if h.has_key?(:top_lvl_tlv)
        tlv = h[:top_lvl_tlv]
        case tlv
        when Hash
          @top_lvl_tlv = OSPFv2::Tlv.factory(tlv)
        when Tlv
          @top_lvl_tlv = tlv
        else
          raise
        end
      end
    end

    def encode
      if top_lvl_tlv
        super top_lvl_tlv.encode
      else
        super
      end
    end
    
    def to_s
      super +
      top_lvl_tlv.to_s
    rescue => e
      # p top_lvl_tlv
      raise
    end

    def parse(s)
      @top_lvl_tlv = Tlv.factory(super(s))
    end
    
  end
  
end

load "../../../test/ospfv2/lsa/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0


__END__


require "test/unit"


class TestTra < Test::Unit::TestCase
  include OSPFv2
  # def _test_case_name
  #   p TrafficEngineering.opaque_id
  #   p TrafficEngineering.opaque_id
  #   p TrafficEngineering.opaque_id
  #   p TrafficEngineering.reset_opaque_id
  #   p TrafficEngineering.opaque_id
  #   p TrafficEngineering.opaque_id
  #   p TrafficEngineering.opaque_id
  # end
  
          # 0                   1                   2                   3
  #        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  #       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #       |            LS age             |     Options   |  9, 10, or 11 |
  #       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #       |  Opaque Type  |               Opaque ID                       |
  #       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #       |                      Advertising Router                       |
  #       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #       |                      LS Sequence Number                       |
  #       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #       |         LS checksum           |           Length              |
  #       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   def _test_new
    assert TrafficEngineering.new
    assert_equal('0000 00 0a 01 000000 00000000 80000001 0a55 0014'.split.join,
                TrafficEngineering.new.to_shex)
    assert_equal('0000000a010000000202020280000001cd890014',
                TrafficEngineering.new(:advertising_router=>'2.2.2.2').to_shex)
    assert_equal('0000000a010000ff0202020280000001cd890014',
                TrafficEngineering.new(:advertising_router=>'2.2.2.2', :opaque_id=>0xff).to_shex)
    require 'pp'
    p TrafficEngineering.new(:advertising_router=>'2.2.2.2', :opaque_id=>0xff)
    
  end
  
  def test_new_hash
    h = {:advertising_router=>"0.0.0.1", :sequence_number=>2147483649, :opaque_id=>255, :opaque_type=>:te_lsa, :top_lvl_tlv=>{:tlv_type=>2, :tlvs=>[{:tlv_type=>1, :length=>1, :link_type=>1}]}, :ls_age=>0, :ls_type=>:area, :options=>0}
    p TrafficEngineering.new_hash h
  end
  
  
  
  def _test_new_te_rid
    # Open Shortest Path First
    #     OSPF Header
    #         OSPF Version: 2
    #         Message Type: LS Acknowledge (5)
    #         Packet Length: 44
    #         Source OSPF Router: 1.1.1.1 (1.1.1.1)
    #         Area ID: 0.0.0.0 (Backbone)
    #         Packet Checksum: 0xa820 [correct]
    #         Auth Type: Null
    #         Auth Data (none)
    #     LSA Header
    #         LS Age: 0 seconds
    #         Do Not Age: False
    #         Options: 0x00 ()
    #             0... .... = DN: DN-bit is NOT set
    #             .0.. .... = O: O-bit is NOT set
    #             ..0. .... = DC: Demand circuits are NOT supported
    #             ...0 .... = L: The packet does NOT contain LLS data block
    #             .... 0... = NP: Nssa is NOT supported
    #             .... .0.. = MC: NOT multicast capable
    #             .... ..0. = E: NO ExternalRoutingCapability
    #         Link-State Advertisement Type: Opaque LSA, Area-local scope (10)
    #         Link State ID Opaque Type: Traffic Engineering LSA (1)
    #         Link State ID TE-LSA Reserved: 0
    #         Link State ID TE-LSA Instance: 255
    #         Advertising Router: 2.2.2.2 (2.2.2.2)
    #         LS Sequence Number: 0x80000001
    #         LS Checksum: 0xcd89
    #         Length: 20
    # 
    # 0000  01 00 5e 00 00 05 cc 00 1d 1f 00 10 08 00 45 c0   ..^...........E.
    # 0010  00 40 7f da 00 00 01 59 fa 0f c0 a8 9e 0d e0 00   .@.....Y........
    # 0020  00 05 02 05 00 2c 01 01 01 01 00 00 00 00 a8 20   .....,......... 
    # 0030  00 00 00 00 00 00 00 00 00 00 00 00 00 0a 01 00   ................
    # 0040  00 ff 02 02 02 02 80 00 00 01 cd 89 00 14         ..............
    # 
    te =  TrafficEngineering.new(:advertising_router=>'2.2.2.2', :opaque_id=>0xff)
    te.top_lvl_tlv = RouterAddress_Tlv.new(:router_address=>"1.1.1.1")
    p te
  end
  
  
end

__END__


  
  # unless const_defined?(:NetworkMask)
  #   NetworkMask = Class.new(Id)
  #   AttachRouter = Class.new(Id)
  # end
  # 
  # attr_reader :network_mask, :attached_routers
  
  def initialize(arg={})
    @network_mask, @attached_routers = nil, []
    @ls_type = LsType.new(:network)
    super
  end
  
  def encode
    lsa=[]
    @network_mask ||= NetworkMask.new
    @attached_routers ||=[]
    lsa << network_mask.encode
    lsa << attached_routers.collect { |x| x.encode }
    super lsa.join
  end
  
  def attached_routers=(val)
    [val].flatten.each { |x| self << x }
  end
  
  def <<(neighbor)
    @attached_routers ||=[]
    @attached_routers << AttachRouter.new(neighbor)
  end
  
  def parse(s)
    network_mask, attached_routers = super(s).unpack('Na*')
    @network_mask = NetworkMask.new network_mask
    while attached_routers.size>0
      self << attached_routers.slice!(0,4).unpack('N')[0]
    end
  end
  
  # Network:
  #    LsAge: 34
  #    Options:  0x22  [DC,E]
  #    LsType: network_lsa
  #    AdvertisingRouter: 192.168.1.200
  #    LsId: 192.168.1.200
  #    SequenceNumber: 0x80000001
  #    LS checksum:  2dc
  #    length: 32
  #    NetworkMask: 255.255.255.0
  #    AttachRouter: 192.168.1.200
  #    AttachRouter: 193.0.0.0
  # FIXME:
  #  when not verbose, only header is displayed and this is taken care of by parent method
  def to_s_verbose(*args)
    super  +
    ['', network_mask, *attached_routers].join("\n   ")
  end
  #   
  # R1#show ip ospf database network 
  # 
  #             OSPF Router with ID (1.1.1.1) (Process ID 1)
  # 
  #                 Net Link States (Area 0)
  # 
  #   Routing Bit Set on this LSA
  #   LS age: 949
  #   Options: (No TOS-capability, DC)
  #   LS Type: Network Links
  #   Link State ID: 192.168.0.2 (address of Designated Router)
  #   Advertising Router: 2.2.2.2
  #   LS Seq Number: 8000000E
  #   Checksum: 0xF9B3
  #   Length: 32
  #   Network Mask: /24
  #         Attached Router: 2.2.2.2
  #         Attached Router: 1.1.1.1
  # 
  # R1#
  # def to_s_ios
  #   attrs = attached_routers.collect { |ar| "      Attached Router #{ar.to_ip}"}
  #   s = []
  #   s << super
  #   s << "Network Mask: " + network_mask.to_s(false)
  #   s << attached_routers.collect { |ar| "      Attached Router #{ar.to_ip}"}
  #   s.join("\n")
  # end
  def to_s_ios_verbose
    attrs = attached_routers.collect { |ar| "      Attached Router #{ar.to_ip}"}
    s = []
    s << super
    s << "Network Mask: " + network_mask.to_s(false)
    s << attached_routers.collect { |ar| "      Attached Router #{ar.to_ip}"}
    s.join("\n  ")
  end

  # FIXME: should be removed and parent take care of it.
  # def to_s_junos
  #   super
  # end

  def to_s_junos_verbose
    mask = "mask #{network_mask.to_ip}"
    attrs = attached_routers.collect { |ar| "attached router #{ar.to_ip}"}
    super +
    ['', mask, *attrs].join("\n  ")
  end
  
end

class Network
  def self.new_hash(h)
    r = new(h)
    r
  end
end

end



__END__


module OSPFv2



  class TrafficEngineering < LSA
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
