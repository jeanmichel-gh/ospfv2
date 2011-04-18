#
#  Created by Jean-Michel Esnault.
#  Copyright (c) 2008. All rights reserved.
#

=begin rdoc

2.3.2.  TLV Header

The LSA payload consists of one or more nested Type/Length/Value
(TLV) triplets for extensibility.  The format of each TLV is:

0                   1                   2                   3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|              Type             |             Length            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                            Value...                           |
.                                                               .
.                                                               .
.                                                               .
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

The Length field defines the length of the value portion in octets
(thus a TLV with no value portion would have a length of zero).  The
TLV is padded to four-octet alignment; padding is not included in the
length field (so a three octet value would have a length of three,
but the total size of the TLV would be eight octets).  Nested TLVs
are also 32-bit aligned.  Unrecognized types are ignored.


=end

require 'infra/ospf_common'
require 'ie/id'

module OSPFv2
  module Tlv
    module Common
      def stlv_len(n)
        (((n+3)/4)*4)+4
      end
      def tlv_len
        @length
      end
      def to_hash
        {:tlv_type=> tlv_type}
      end
    end
  end
  module SubTlv
    include Tlv
  end
end


__END__



# class Factory
#   def TLV_Factory.create(arg={})
#     type=nil
#     if arg.is_a?(Hash)
#       type = arg[:tlv_type]
#     elsif arg.is_a?(String)
#       type = arg[0..1].unpack('n')[0]
#     end
#     return nil if type.nil?
#     case type
#     when 1 ; RouterID_TLV.new(arg)
#     when 2 ; LinkTLV.new(arg)
#     end
#   end  
# end


#
#  Created by Jean-Michel Esnault.
#  Copyright (c) 2008. All rights reserved.
#

require 'test/unit'
require 'lsa_traffic_engineering'
require 'pp'
require 'opaque_tlvs'
require 'sequence_number'

class RouterID_TLV_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    assert_equal("0001000400000000", RouterID_TLV.new().to_shex)
    assert_equal("RouterID TLV: 1.1.1.1", RouterID_TLV.new({:rid=>"1.1.1.1"}).to_s)
    assert_equal("1.1.1.1", RouterID_TLV.new({:rid=>"1.1.1.1"}).to_hash[:rid])
    assert_equal("0001000401010101", RouterID_TLV.new({:rid=>"1.1.1.1"}).to_shex)
    assert_equal("0001000401010101", RouterID_TLV.new(RouterID_TLV.new({:rid=>"1.1.1.1"}).enc).to_shex)
    assert_equal(true, RouterID_TLV.new({:rid=>"1.1.1.1"}).is_a?(TLV))
  end
end
class LinkTypeSubTLV_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    assert_equal("0001000100000000", LinkTypeSubTLV.new().to_shex)
    assert_equal("Ospf::LinkTypeSubTLV: point-to-point", LinkTypeSubTLV.new({:link_type=>1}).to_s)
    assert_equal("Ospf::LinkTypeSubTLV: multiaccess", LinkTypeSubTLV.new({:link_type=>2}).to_s)
    assert_equal(1, LinkTypeSubTLV.new({:link_type=>1}).to_hash[:link_type])
    assert_equal("0001000101000000", LinkTypeSubTLV.new({:link_type=>1}).to_shex)
    assert_equal("0001000101000000", LinkTypeSubTLV.new(LinkTypeSubTLV.new({:link_type=>1}).enc).to_shex)
    assert_equal(true, LinkTypeSubTLV.new({:link_type=>1}).kind_of?(SubTLV))
  end
end
class LinkID_SubTLV_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    assert_equal("0002000400000000", LinkID_SubTLV.new().to_shex)
    assert_equal("Ospf::LinkID_SubTLV: 1.1.1.1", LinkID_SubTLV.new({:link_id=>"1.1.1.1"}).to_s)
    assert_equal("1.1.1.1", LinkID_SubTLV.new({:link_id=>"1.1.1.1"}).to_hash[:link_id])
    assert_equal("0002000401010101", LinkID_SubTLV.new({:link_id=>"1.1.1.1"}).to_shex)
    assert_equal("0002000401010101", LinkID_SubTLV.new(LinkID_SubTLV.new({:link_id=>"1.1.1.1"}).enc).to_shex)
  end
end
class LocalInterfaceIP_Address_SubTLV_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    assert_equal("00030000", LocalInterfaceIP_Address_SubTLV.new().to_shex)
    assert_equal("Ospf::LocalInterfaceIP_Address_SubTLV: 1.1.1.1", LocalInterfaceIP_Address_SubTLV.new({:local_interface_ip_address=>"1.1.1.1"}).to_s)
    assert_equal("1.1.1.1", LocalInterfaceIP_Address_SubTLV.new({:local_interface_ip_address=>"1.1.1.1"}).to_hash[:local_interface_ip_address][0])
    assert_equal("0003000401010101", 
    LocalInterfaceIP_Address_SubTLV.new(LocalInterfaceIP_Address_SubTLV.new({:local_interface_ip_address=>"1.1.1.1"}).enc).to_shex)
    assert_equal("0003000c010101010202020203030303",
    LocalInterfaceIP_Address_SubTLV.new({:local_interface_ip_address=>["1.1.1.1", "2.2.2.2", "3.3.3.3"]}).to_shex)
    assert_equal("2.2.2.2",LocalInterfaceIP_Address_SubTLV.new({:local_interface_ip_address=>["1.1.1.1", "2.2.2.2", "3.3.3.3"]}).to_hash[:local_interface_ip_address][1])
    tlv1 = LocalInterfaceIP_Address_SubTLV.new(["0003000c010101010202020203030303"].pack('H*'))
    tlv2 = LocalInterfaceIP_Address_SubTLV.new(tlv1.enc)
    assert_equal(tlv2.enc, tlv1.enc)
  end
end
class RemoteInterfaceIP_Address_SubTLV_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    assert_equal("00040000", RemoteInterfaceIP_Address_SubTLV.new().to_shex)
    assert_equal("Ospf::RemoteInterfaceIP_Address_SubTLV: 1.1.1.1", RemoteInterfaceIP_Address_SubTLV.new({:remote_interface_ip_address=>"1.1.1.1"}).to_s)
    assert_equal("1.1.1.1", RemoteInterfaceIP_Address_SubTLV.new({:remote_interface_ip_address=>"1.1.1.1"}).to_hash[:remote_interface_ip_address][0])
    assert_equal("0004000401010101", RemoteInterfaceIP_Address_SubTLV.new({:remote_interface_ip_address=>"1.1.1.1"}).to_shex)
    assert_equal("0004000401010101", RemoteInterfaceIP_Address_SubTLV.new(RemoteInterfaceIP_Address_SubTLV.new({:remote_interface_ip_address=>"1.1.1.1"}).enc).to_shex)
    assert_equal("2.2.2.2",RemoteInterfaceIP_Address_SubTLV.new({:remote_interface_ip_address=>["1.1.1.1", "2.2.2.2", "3.3.3.3"]}).to_hash[:remote_interface_ip_address][1])
    tlv1 = RemoteInterfaceIP_Address_SubTLV.new(["0003000c010101010202020203030303"].pack('H*'))
    tlv2 = RemoteInterfaceIP_Address_SubTLV.new(tlv1.enc)
    assert_equal(tlv2.enc, tlv1.enc)
  end
end
class TE_MetricSubTLV_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    assert_equal("0005000400000000", TE_MetricSubTLV.new().to_shex)
    assert_equal("Ospf::TE_MetricSubTLV: 254", TE_MetricSubTLV.new({:te_metric=>254}).to_s)
    assert_equal(255, TE_MetricSubTLV.new({:te_metric=>255}).to_hash[:te_metric])
    assert_equal("000500040000ffff", TE_MetricSubTLV.new(TE_MetricSubTLV.new({:te_metric=>0xffff}).enc).to_shex)
  end
end
class MaximumBandwidth_SubTLV_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    assert_equal("0006000400000000", MaximumBandwidth_SubTLV.new().to_shex)
    assert_equal("Ospf::MaximumBandwidth_SubTLV: 254", MaximumBandwidth_SubTLV.new({:max_bw=>254}).to_s)
    assert_equal(255, MaximumBandwidth_SubTLV.new({:max_bw=>255}).to_hash[:max_bw])
    assert_equal("0006000445ffff00", MaximumBandwidth_SubTLV.new({:max_bw=>0xffff}).to_shex)
  end
end
class MaximumReservableBandwidth_SubTLV_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    assert_equal("0007000400000000", MaximumReservableBandwidth_SubTLV.new().to_shex)
    assert_equal("Ospf::MaximumReservableBandwidth_SubTLV: 254", MaximumReservableBandwidth_SubTLV.new({:max_resv_bw=>254}).to_s)
    assert_equal(255, MaximumReservableBandwidth_SubTLV.new({:max_resv_bw=>255}).to_hash[:max_resv_bw])
    assert_equal("0007000445fff800", MaximumReservableBandwidth_SubTLV.new(MaximumReservableBandwidth_SubTLV.new({:max_resv_bw=>0xffff}).enc).to_shex)
  end
end
class UnreservedBandwidth_SubTLV_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    assert_equal("00080000", UnreservedBandwidth_SubTLV.new().to_shex)
    assert_equal("Ospf::UnreservedBandwidth_SubTLV: 0, 0, 0, 0, 0, 0, 0, 0", UnreservedBandwidth_SubTLV.new({:unreserved_bw=>[0,0,0,0,0,0,0,0]}).to_s)
    assert_equal([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0], UnreservedBandwidth_SubTLV.new({:unreserved_bw=>[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]}).to_hash[:unreserved_bw])
    assert_equal("000800203e0000003e8000003ec000003f0000003f2000003f4000003f6000003f800000".split.join, 
    UnreservedBandwidth_SubTLV.new({:unreserved_bw=>[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]}).to_shex)
    assert_equal(32, 
    UnreservedBandwidth_SubTLV.new({:unreserved_bw=>[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]}).length)
  end
end
class SubTLV_Factory_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    assert_equal("0001000101000000", SubTLV_Factory.create({:tlv_type=>1, :link_type=>1}).to_shex)
    assert_equal(Ospf::LinkTypeSubTLV, SubTLV_Factory.create({:tlv_type=>1, :link_type=>1}).class)
    assert_equal("0002000401010101", SubTLV_Factory.create({:tlv_type=>2, :link_id=>"1.1.1.1"}).to_shex)
    assert_equal(Ospf::LinkID_SubTLV, SubTLV_Factory.create({:tlv_type=>2, :link_id=>"1.1.1.1"}).class)
    assert_equal("0003000401010101", SubTLV_Factory.create({:tlv_type=>3, :local_interface_ip_address=>"1.1.1.1"}).to_shex)
    assert_equal(Ospf::LocalInterfaceIP_Address_SubTLV, SubTLV_Factory.create({:tlv_type=>3, :local_interface_ip_address=>"1.1.1.1"}).class)
  end
end
class LinkTLV_Test < Test::Unit::TestCase # :nodoc:
  include Ospf

  def setup
    @link_tlv = LinkTLV.new()    
    link_type = LinkTypeSubTLV.new({:link_type=>1})
    link_id = LinkID_SubTLV.new({:link_id=>'12.1.1.1'})
    local_if_addr = LocalInterfaceIP_Address_SubTLV.new({:local_interface_ip_address => '192.168.208.86', })
    rmt_if_addr = RemoteInterfaceIP_Address_SubTLV.new({:remote_interface_ip_address =>  '192.168.208.87', })
    te_metric = TE_MetricSubTLV.new({:te_metric => 1, })
    max_bw = MaximumBandwidth_SubTLV.new({:max_bw => 155.52*1000000, })
    max_resv_bw = MaximumReservableBandwidth_SubTLV.new({:max_resv_bw => 155.52*1000000, })
    unresv_bw = UnreservedBandwidth_SubTLV.new({:unreserved_bw => [155.52*1000000]*8, })
    @link_tlv << link_type << link_id << local_if_addr << rmt_if_addr << te_metric << max_bw << max_resv_bw << unresv_bw
    @te_lsa = TrafficEngineeringLSA.new({:advr=>'0.1.0.1',})  # default to area lstype 10
    @te_lsa << @link_tlv
  end

  def test_init
    link_type = SubTLV_Factory.create({:tlv_type=>1, :link_type=>1})
    link_id = SubTLV_Factory.create({:tlv_type=>2, :link_id=>"1.1.1.1"})
    #             type len  type len  va filler type len  value
    assert_equal("0002 0010 0001 0001 01 000000 0002 0004 01010101".split.join, 
    (LinkTLV.new() << link_type << link_id).to_shex)
    link_type = SubTLV_Factory.create({:tlv_type=>1, :link_type=>1})
    link_id = SubTLV_Factory.create({:tlv_type=>2, :link_id=>"1.1.1.1"})
    rmt_ip = RemoteInterfaceIP_Address_SubTLV.new({:remote_interface_ip_address=>"1.1.1.1"})
    l = LinkTLV.new() 
    l << link_type
    l << link_id
    l = LinkTLV.new() << link_type << link_id << rmt_ip
    l.to_shex
    l.to_hash
    l1  = LinkTLV.new(l.enc)
    assert_equal(1,l1.tlvs[0].to_hash[:link_type])
    assert_equal(l1.to_shex, l.to_shex)
  end
  def test_tlv_type_1
    link_type = SubTLV_Factory.create(['0001000101000000'].pack('H*'))
    assert_equal(LinkTypeSubTLV,link_type.class) 
  end
  def test_tlv_type_2
    link_type = SubTLV_Factory.create(['000200040afff530'].pack('H*'))
    assert_equal(LinkID_SubTLV,link_type.class) 
  end
  def test_tlv_type_3
    link_type = SubTLV_Factory.create(['0003 0004 c0a8 a431'.split.join].pack('H*'))
    assert_equal(LocalInterfaceIP_Address_SubTLV,link_type.class) 
    assert_match(/192\.168\.164\.49/, link_type.to_s)
  end
  def test_tlv_type_4
    link_type = SubTLV_Factory.create(['0004 0004 c0a8 a430'.split.join].pack('H*'))
    assert_equal(RemoteInterfaceIP_Address_SubTLV,link_type.class) 
  end
  def test_tlv_type_5
    link_type = SubTLV_Factory.create(['0005 0004 0000 0001'.split.join].pack('H*'))
    assert_equal(TE_MetricSubTLV,link_type.class) 
  end
  def test_tlv_type_6
    link_type = SubTLV_Factory.create(['0006 0004 4b3e bc20'.split.join].pack('H*'))
    assert_equal(MaximumBandwidth_SubTLV,link_type.class) 
    assert_equal(100000000.0,link_type.max_bw) 
    assert_equal({:tlv_type=>6, :max_bw=>100000000.0},link_type.to_hash) 
    assert_equal('000600044b3ebc20', SubTLV_Factory.create({:tlv_type=>6, :max_bw=>100000000.0}).to_shex) 
    assert_equal(MaximumBandwidth_SubTLV,link_type.class) 
    assert_equal(100000000.0,link_type.max_bw)  
  end  
  def test_tlv_type_7
    link_type = SubTLV_Factory.create(['0007 0004 4b3e bc20'.split.join].pack('H*'))
    assert_equal(MaximumReservableBandwidth_SubTLV,link_type.class) 
    assert_equal(100000000.0, link_type.max_resv_bw)

  end
  def test_tlv_type_8
    link_type = SubTLV_Factory.create(['0008 0020 4b3e bc20 4b3e bc20 4b3e bc20 4b3e bc20 4b3e bc20 4b3e bc20 4b3e bc20 4b3e bc20 '.split.join].pack('H*'))
    assert_equal(100000000.0, link_type.unreserved_bw[0]) 
    link_type = SubTLV_Factory.create(['0008 0020 4b94 50c0
      4b94 50c0 4b94 50c0 4b94 50c0 4b94 50c0
      4b94 50c0 4b94 50c0 4b94 50c0 '.split.join].pack('H*'))
      assert_equal(UnreservedBandwidth_SubTLV,link_type.class) 
      assert_equal(155520000.0, link_type.unreserved_bw[0])
      assert_equal("Ospf::UnreservedBandwidth_SubTLV: 155520000.0, 155520000.0, 155520000.0, 155520000.0, 155520000.0, 155520000.0, 155520000.0, 155520000.0", link_type.to_s) 
    end
    def test_tlv_type_9
      stlv = SubTLV_Factory.create(['0009 0004 0000 0001'.split.join].pack('H*'))
      assert_equal(Color_SubTLV,stlv.class) 
      assert_equal(1,stlv.color)
    end
    def test_link_tlv_has?
      assert_equal(8, @link_tlv.has?.size) 
      assert_equal(LinkTypeSubTLV,@link_tlv.has?[0])
      assert_equal(true, @link_tlv.has?(LinkTypeSubTLV))
    end
    def test_link_tlv_index
      assert_equal(LinkTypeSubTLV, @link_tlv[LinkTypeSubTLV].class)
      assert_equal(LinkTypeSubTLV, @link_tlv.find(LinkTypeSubTLV).class)
      assert_equal(['192.168.208.87'], @link_tlv[RemoteInterfaceIP_Address_SubTLV].remote_interface_ip_address)
    end
    def test_link_tlv_replace
      rmt_ip = RemoteInterfaceIP_Address_SubTLV.new({:remote_interface_ip_address=>"1.1.1.1"})
      @link_tlv.replace(rmt_ip)
      assert_equal(['1.1.1.1'], @link_tlv[RemoteInterfaceIP_Address_SubTLV].remote_interface_ip_address)
    end
    def test_link_tlv_remove
      @link_tlv.remove(RemoteInterfaceIP_Address_SubTLV)
      assert_nil(@link_tlv[RemoteInterfaceIP_Address_SubTLV])
    end

    def test_link_tlv_create
      h={}
      h.store(:link_type,1)
      h.store(:link_id,'1.1.1.1')
      h.store(:local_interface_ip_address,'1.2.3.4')
      h.store(:remote_interface_ip_address,'5.6.7.8')
      h.store(:te_metric,10)
      h.store(:max_bw,1.0*10**9)
      h.store(:max_resv_bw,1.0*10**9)
      h.store(:unreserved_bw,[1.0*10**9]*8)
      link_tlv = Ospf::LinkTLV.create(h)
      assert_equal(1,link_tlv[LinkTypeSubTLV].link_type)
      assert_equal('1.1.1.1',link_tlv[LinkID_SubTLV ].link_id)
      assert_equal(['1.2.3.4'],link_tlv[LocalInterfaceIP_Address_SubTLV].local_interface_ip_address)
      assert_equal(['5.6.7.8'],link_tlv[RemoteInterfaceIP_Address_SubTLV].remote_interface_ip_address)
      assert_equal(10,link_tlv[TE_MetricSubTLV].te_metric)
      assert_equal(1000000000.0,link_tlv[MaximumBandwidth_SubTLV].max_bw)
      assert_equal(1000000000.0,link_tlv[MaximumReservableBandwidth_SubTLV].max_resv_bw)
      assert_equal([1000000000.0]*8,link_tlv[UnreservedBandwidth_SubTLV].unreserved_bw)
    end

    def test_te_lsa_2

      #####  	  LSA #3
      #####  	  Advertising Router 10.255.245.46, seq 0x8000001e, age 8s, length 104
      #####  	    Area Local Opaque LSA (10), Opaque-Type Traffic Engineering LSA (1), Opaque-ID 5
      #####  	    Options: [External, Demand Circuit]
      #####  	    Link TLV (2), length: 100
      #####  	      Link Type subTLV (1), length: 1, Point-to-point (1)
      #####  	      Link ID subTLV (2), length: 4, 12.1.1.1 (0x0c010101)
      #####  	      Local Interface IP address subTLV (3), length: 4, 192.168.208.88
      #####  	      Remote Interface IP address subTLV (4), length: 4, 192.168.208.89
      #####  	      Traffic Engineering Metric subTLV (5), length: 4, Metric 1
      #####  	      Maximum Bandwidth subTLV (6), length: 4, 155.520 Mbps
      #####  	      Maximum Reservable Bandwidth subTLV (7), length: 4, 155.520 Mbps
      #####  	      Unreserved Bandwidth subTLV (8), length: 32
      #####  		TE-Class 0: 155.520 Mbps
      #####  		TE-Class 1: 155.520 Mbps
      #####  		TE-Class 2: 155.520 Mbps
      #####  		TE-Class 3: 155.520 Mbps
      #####  		TE-Class 4: 155.520 Mbps
      #####  		TE-Class 5: 155.520 Mbps
      #####  		TE-Class 6: 155.520 Mbps
      #####  		TE-Class 7: 155.520 Mbps
      #####  	      Administrative Group subTLV (9), length: 4, 0x00000000
      #####  			 0200 0000 45c0 01b0 d0ff 0000 0159 7520
      #####  			 c0a8 d067 e000 0005 0204 019c 0aff f531
      #####  			 0000 0000 2dde 0000 0000 0000 0000 0000
      #####  			 0000 0003 000a 2202 c0a8 a42f 0c01 0101
      #####  			 8000 0eba b7e3 0020 ffff fc00 0c01 0101
      #####  			 7c01 0001 000a 2201 0c01 0101 0c01 0101
      #####  			 8000 3313 0ed3 00e4 0000 0011 c0a8 d043
      #####  			 c0a8 d044 0200 0001 c0a8 a42f c0a8 a42f
      #####  			 0200 0001 0c01 0101 ffff ffff 0300 0000
      #####  			 0aff f52f ffff ffff 0300 0000 7c01 0101
      #####  			 7c01 0002 0200 0001 7c01 0201 7c01 0003
      #####  			 0200 0001 0a01 0000 ffff 0000 0300 0001
      #####  			 0a01 0000 ffff 0000 0300 0001 0a02 0000
      #####  			 ffff 0000 0300 0001 0a01 0000 ffff 0000
      #####  			 0300 0001 0a02 0000 ffff 0000 0300 0001
      #####  			 0aff f52e c0a8 d05b 0100 0001 c0a8 d05a
      #####  			 ffff fffe 0300 0001 0aff f52e c0a8 d059
      #####  			 0100 0001 c0a8 d058 ffff fffe 0300 0001
      #####  			 0aff f52e c0a8 d057 0100 0001 c0a8 d056
      #####  			 ffff fffe 0300 0001 0008 220a 0100 0005
      #####  			 0aff f52e 8000 001e d240 007c 0002 0064
      #####  			 0001 0001 0100 0000 0002 0004 0c01 0101
      #####  			 0003 0004 c0a8 d058 0004 0004 c0a8 d059
      #####  			 0005 0004 0000 0001 0006 0004 4b94 50c0
      #####  			 0007 0004 4b94 50c0 0008 0020 4b94 50c0
      #####  			 4b94 50c0 4b94 50c0 4b94 50c0 4b94 50c0
      #####  			 4b94 50c0 4b94 50c0 4b94 50c0 0009 0004
      #####  			 0000 0000

      te_lsa_shex = %{
        0008 220a 0100 0005
        0aff f52e 8000 001e d240 007c 0002 0064
        0001 0001 0100 0000 0002 0004 0c01 0101
        0003 0004 c0a8 d058 0004 0004 c0a8 d059
        0005 0004 0000 0001 0006 0004 4b94 50c0
        0007 0004 4b94 50c0 0008 0020 4b94 50c0
        4b94 50c0 4b94 50c0 4b94 50c0 4b94 50c0
        4b94 50c0 4b94 50c0 4b94 50c0 0009 0004
        0000 0000
        }.split.join

        link_tlv = LinkTLV.new()    
        link_type = LinkTypeSubTLV.new({:link_type=>1})
        link_id = LinkID_SubTLV.new({:link_id=>'12.1.1.1'})
        local_if_addr = LocalInterfaceIP_Address_SubTLV.new({:local_interface_ip_address => '192.168.208.88', })
        rmt_if_addr = RemoteInterfaceIP_Address_SubTLV.new({:remote_interface_ip_address =>  '192.168.208.89', })
        te_metric = TE_MetricSubTLV.new({:te_metric => 1, })
        max_bw = MaximumBandwidth_SubTLV.new({:max_bw => 155.52*1000000, })
        max_resv_bw = MaximumReservableBandwidth_SubTLV.new({:max_resv_bw => 155.52*1000000, })
        unresv_bw = UnreservedBandwidth_SubTLV.new({:unreserved_bw => [155.52*1000000]*8, })
        color = Color_SubTLV.new({:color=>0})
        link_tlv << link_type << link_id << local_if_addr << rmt_if_addr << te_metric << max_bw << max_resv_bw << unresv_bw << color
        te_lsa = TrafficEngineeringLSA.new({:advr=>'10.255.245.46',:lsage=>8, :options => 0x22, :seqn=> 0x8000001e, :opaque_id => 5, })  # default to area lstype 10
        te_lsa << link_tlv
        assert_equal(te_lsa_shex, te_lsa.to_shex)
        #puts te_lsa.to_s_junos_style
        #puts te_lsa

      end

      def test_tlv_type_11
        #TODO unit test tlv type 11
      end

    end




    =begin rdoc

    2.4.2.  Link TLV

    The Link TLV describes a single link.  It is constructed of a set of
    sub-TLVs.  There are no ordering requirements for the sub-TLVs.

    Only one Link TLV shall be carried in each LSA, allowing for fine
    granularity changes in topology.

    The Link TLV is type 2, and the length is variable.

    The following sub-TLVs of the Link TLV are defined:

    1 - Link type (1 octet)
    2 - Link ID (4 octets)
    3 - Local interface IP address (4 octets)
    4 - Remote interface IP address (4 octets)
    5 - Traffic engineering metric (4 octets)
    6 - Maximum bandwidth (4 octets)
    7 - Maximum reservable bandwidth (4 octets)
    8 - Unreserved bandwidth (32 octets)
    9 - Administrative group (4 octets)

    This memo defines sub-Types 1 through 9.  See the IANA Considerations
    section for allocation of new sub-Types.

    The Link Type and Link ID sub-TLVs are mandatory, i.e., must appear
    exactly once.

    All other sub-TLVs defined here may occur at most
    once.  These restrictions need not apply to future sub-TLVs.
    Unrecognized sub-TLVs are ignored.

    Various values below use the (32 bit) IEEE Floating Point format.
    For quick reference, this format is as follows:

    0                   1                   2                   3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |S|    Exponent   |                  Fraction                   |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

    S is the sign, Exponent is the exponent base 2 in "excess 127"
    notation, and Fraction is the mantissa - 1, with an implied binary
    point in front of it.  Thus, the above represents the value:

    (-1)**(S) * 2**(Exponent-127) * (1 + Fraction)

    For more details, refer to [4].

    =end

    class LinkTLV < TLV
      include Ospf

      attr_reader :tlv_type, :length, :tlvs

      def initialize(arg={})
        @tlv_type, @length, @tlvs = 2, 0, []
        if arg.is_a?(Hash) then
          set(arg)
        elsif arg.is_a?(String)
          __parse(arg)
        else
          raise ArgumentError, "Invalid argument", caller
        end
        self
      end

      def add(tlv)
        if tlv.is_a?(Ospf::SubTLV)
          @tlvs << tlv
        end
        self
      end

      def <<(tlv)
        add(tlv)
      end

      def set(arg)
        return self unless arg.is_a?(Hash)
        unless arg[:tlvs].nil?
          arg[:tlvs].each { |tlv| 
            tlv.is_a?(SubTLV) ? @tlvs << tlv : @tlvs << SubTLV.new(tlv) 
          }
        end
        self
      end

      def enc
        _tlvs =  @tlvs.collect { |tlv| tlv.enc }.join
        @length = _tlvs.size
        s = __enc([
          [@tlv_type,  'n'], 
          [@length, 'n'], 
          ])
          s += _tlvs
          s
        end

        def __parse(s)
          arr = s.unpack('nn')
          @tlv_type = arr[0]
          @length= arr[1]
          tlvs = s[4..-1]
          while tlvs.size>0
            len = tlvs[2..3].unpack('n')[0]
            @tlvs << SubTLV_Factory.create(tlvs.slice!(0,__stlv_len(len)))
          end
        end
        private :__parse

        def to_hash
          {
            :tlv_type => tlv_type,
            :tlvs => @tlvs.collect { |tlv| tlv.to_hash }
          }
        end

        def to_s
          @length =  @tlvs.collect { |tlv| tlv.enc }.join.size
          self.class.to_s + "(2): " + "\n" +
          @tlvs.collect { |tlv| tlv.to_s }.join("\n")
        end

        def to_s_junos_style(ident=0)
          s = "  "* ident + "Link (2), length #{@length}:\n"
          s += @tlvs.collect { |tlv| tlv.to_s_junos_style(ident+1) }.join("\n")
        end

        def self.create(args={})
          link_tlv = LinkTLV.new()   
          link_type, link_id, local_if_addr, rmt_if_addr, te_metric, max_bw, max_resv_bw = nil, nil, nil, nil, nil, nil, nil    
          link_type = LinkTypeSubTLV.new(args) if args.has_key?(:link_type)
          link_id = LinkID_SubTLV.new(args) if args.has_key?(:link_id)
          local_if_addr = LocalInterfaceIP_Address_SubTLV.new(args) if args.has_key?(:local_interface_ip_address)
          rmt_if_addr = RemoteInterfaceIP_Address_SubTLV.new(args) if args.has_key?(:remote_interface_ip_address)
          te_metric = TE_MetricSubTLV.new(args) if args.has_key?(:te_metric)
          max_bw = MaximumBandwidth_SubTLV.new(args) if args.has_key?(:max_bw)
          max_resv_bw = MaximumReservableBandwidth_SubTLV.new(args) if args.has_key?(:max_resv_bw)
          unresv_bw = UnreservedBandwidth_SubTLV.new(args) if args.has_key?(:unreserved_bw)
          [link_type, link_id, local_if_addr, rmt_if_addr, te_metric, max_bw, max_resv_bw, unresv_bw].each do |sub_tlv|
            link_tlv << sub_tlv unless sub_tlv.nil?
          end
          link_tlv    
        end

        def has?(klass=nil)
          if klass.nil?
            return tlvs.collect { |tlv| tlv.class }
          else
            return tlvs.find { |tlv| tlv.is_a?(klass) }.nil? ? false : true
          end
        end    

        def find(klass)
          tlvs.find { |a| a.is_a?(klass) }
        end

        def __index(klass)
          i=-1
          tlvs.find { |a| i +=1 ; a.is_a?(klass) }
          i
        end
        private :__index

        def replace(*objs)
          objs.each do |obj|  
            if has?(obj.class)
              index = __index(obj.class)
              tlvs[index]=obj
            else
              add(obj)
            end
          end
          self
        end

        def remove(klass) 
          tlvs.delete_if { |a| a.is_a?(klass) }
        end

        def [](klass)
          find(klass)
        end

      end

      class SubTLV

        def tlv_length
          @length
        end

        def to_hash
          {:tlv_type=> tlv_type}
        end

      end


      class SubTLV_Factory

        def SubTLV_Factory.create(arg={})
          if arg.is_a?(Hash)
            return nil if arg[:tlv_type].nil?
            type = arg[:tlv_type]
          elsif arg.is_a?(String)
            # assume we got it from the wire, i.e. it's packed.
            type = arg[0..1].unpack('n')[0]
          else
            return 
          end

          case type
          when 1 ; LinkTypeSubTLV.new(arg)
          when 2 ; LinkID_SubTLV.new(arg)
          when 3 ; LocalInterfaceIP_Address_SubTLV.new(arg)
          when 4 ; RemoteInterfaceIP_Address_SubTLV.new(arg)
          when 5 ; TE_MetricSubTLV.new(arg)
          when 6 ; MaximumBandwidth_SubTLV.new(arg)
          when 7 ; MaximumReservableBandwidth_SubTLV.new(arg)
          when 8 ; UnreservedBandwidth_SubTLV.new(arg)
          when 9 ; Color_SubTLV.new(arg)
          end

        end

      end


      =begin rdoc  
      2.5.1.  Link Type

      The Link Type sub-TLV defines the type of the link:

      1 - Point-to-point
      2 - Multi-access

      The Link Type sub-TLV is TLV type 1, and is one octet in length.
      =end

      class LinkTypeSubTLV < SubTLV
        include Ospf
        include Ospf::Ip

        attr_reader :tlv_type, :length, :link_type
        attr_writer :link_type

        def initialize(arg={})
          @tlv_type, @length, @link_type = 1,1,0
          if arg.is_a?(Hash) then
            set(arg)
          elsif arg.is_a?(String)
            __parse(arg)
          else
            raise ArgumentError, "Invalid argument", caller
          end
        end

        def link_type=(arg)
          @link_type=ip2long(arg[:link_type]) unless arg[:link_type].nil?
        end

        def link_type_to_s
          if @link_type==1
            "point-to-point"
          elsif @link_type==2
            "multiaccess"
          else
            "bogus(#{@link_type})"
          end
        end

        def set(arg)
          return self unless arg.is_a?(Hash)
          self.link_type=arg
        end

        def enc
          __enc([
            [@tlv_type, 'n'], 
            [@length, 'n'], 
            [@link_type, 'C'], 
            [[0,0,0], 'C3'], 
            ])
          end

          def __parse(s)
            arr = s.unpack('nnC')
            @tlv_type = arr[0]
            @length= arr[1]
            @link_type = arr[2]
          end
          private :__parse


          def to_hash
            h = super
            h[:link_type] = @link_type
            h
          end

          def to_s
            self.class.to_s + ": " + link_type_to_s
          end

          def to_s_junos_style(ident=0)
            "  "*ident + "Linktype (1), length #{@length}:\n  #{"  "*ident}#{@link_type}"
          end

        end


        =begin rdoc  
        2.5.2.  Link ID

        The Link ID sub-TLV identifies the other end of the link.  For
        point-to-point links, this is the Router ID of the neighbor.  For
        multi-access links, this is the interface address of the designated
        router.  The Link ID is identical to the contents of the Link ID
        field in the Router LSA for these link types.

        The Link ID sub-TLV is TLV type 2, and is four octets in length.

        =end

        class LinkID_SubTLV < SubTLV
          include Ospf
          include Ospf::Ip

          attr_reader :tlv_type, :length

          def initialize(arg={})
            @tlv_type, @length, @link_id = 2,4,0
            if arg.is_a?(Hash) then
              set(arg)
            elsif arg.is_a?(String)
              __parse(arg)
            else
              raise ArgumentError, "Invalid argument", caller
            end
          end

          def link_id=(arg)
            @link_id=ip2long(arg[:link_id]) unless arg[:link_id].nil?
          end

          def set(arg)
            return self unless arg.is_a?(Hash)
            self.link_id=arg
          end

          def enc
            __enc([
              [@tlv_type,  'n'], 
              [@length, 'n'], 
              [@link_id, 'N'], 
              ])
            end

            def __parse(s)
              arr = s.unpack('nnN')
              @tlv_type = arr[0]
              @length= arr[1]
              @link_id = arr[2]
            end
            private :__parse


            def link_id
              long2ip(@link_id)
            end

            def to_hash
              h = super
              h[:link_id]=link_id
              h
            end

            def to_s
              self.class.to_s + ": " + link_id
            end

            def to_s_junos_style(ident=0)
              "  "*ident + "LinkID (2), length #{@length}:\n  #{"  "*ident}#{link_id}"
            end

          end


          =begin rdoc  

          2.5.3.  Local Interface IP Address

          The Local Interface IP Address sub-TLV specifies the IP address(es)
          of the interface corresponding to this link.  If there are multiple
          local addresses on the link, they are all listed in this sub-TLV.

          The Local Interface IP Address sub-TLV is TLV type 3, and is 4N
          octets in length, where N is the number of local addresses.

          =end


          class LocalInterfaceIP_Address_SubTLV <  SubTLV
            include Ospf
            include Ospf::Ip

            attr_reader :tlv_type

            def initialize(arg={})
              @tlv_type, @local_interface_ip_address = 3,[]
              if arg.is_a?(Hash) then
                set(arg)
              elsif arg.is_a?(String)
                __parse(arg)
              else
                raise ArgumentError, "Invalid argument", caller
              end
            end

            def local_interface_ip_address=(arg)
              unless arg[:local_interface_ip_address].nil?
                [arg[:local_interface_ip_address]].flatten.each {|addr|
                  @local_interface_ip_address << ip2long(addr)
                }
              end
            end

            def set(arg)
              return self unless arg.is_a?(Hash)
              self.local_interface_ip_address=arg
            end

            def enc
              s = __enc([
                [@tlv_type,  'n'], 
                [length, 'n'], 
                ])
                s += @local_interface_ip_address.pack('N*')        
              end

              def __parse(s)
                arr = s.unpack('nnN*')
                @tlv_type = arr[0]
                length= arr[1]
                @local_interface_ip_address = arr[2..-1]
              end
              private :__parse


              def local_interface_ip_address
                @local_interface_ip_address.collect {|addr| long2ip(addr) }
              end

              def to_hash
                h=super
                h[:local_interface_ip_address] = local_interface_ip_address
                h
              end

              def length
                @local_interface_ip_address.flatten.size*4
              end

              def to_s
                self.class.to_s + ": " + local_interface_ip_address.join(", ")
              end

              def to_s_junos_style(ident=0)
                s = "  "*ident + "LocIfAdr (3), length #{length}:"
                s += local_interface_ip_address.collect {|addr| "\n  #{"  "*ident}#{addr}"}.join
              end

            end


            =begin rdoc

            2.5.4.  Remote Interface IP Address

            The Remote Interface IP Address sub-TLV specifies the IP address(es)
            of the neighbor's interface corresponding to this link.  This and the
            local address are used to discern multiple parallel links between
            systems.  If the Link Type of the link is Multi-access, the Remote
            Interface IP Address is set to 0.0.0.0; alternatively, an
            implementation MAY choose not to send this sub-TLV.

            The Remote Interface IP Address sub-TLV is TLV type 4, and is 4N
            octets in length, where N is the number of neighbor addresses.

            =end

            class RemoteInterfaceIP_Address_SubTLV <  SubTLV
              include Ospf
              include Ospf::Ip

              attr_reader :tlv_type

              def initialize(arg={})
                @tlv_type, @remote_interface_ip_address = 4,[]
                if arg.is_a?(Hash) then
                  set(arg)
                elsif arg.is_a?(String)
                  __parse(arg)
                else
                  raise ArgumentError, "Invalid argument", caller
                end
              end

              def remote_interface_ip_address=(arg)
                unless arg[:remote_interface_ip_address].nil?
                  [arg[:remote_interface_ip_address]].flatten.each { |addr|
                    @remote_interface_ip_address << ip2long(addr)
                  }
                end
              end

              def set(arg)
                return self unless arg.is_a?(Hash)
                self.remote_interface_ip_address=arg
              end

              def enc
                s = __enc([
                  [@tlv_type,  'n'], 
                  [length, 'n'], 
                  ])
                  s += @remote_interface_ip_address.pack('N*')        
                end

                def __parse(s)
                  arr = s.unpack('nnN*')
                  @tlv_type = arr[0]
                  length= arr[1]
                  @remote_interface_ip_address = arr[2..-1]
                end
                private :__parse

                def remote_interface_ip_address
                  @remote_interface_ip_address.collect {|addr| long2ip(addr) }
                end

                def to_hash
                  h=super
                  h[:remote_interface_ip_address] = remote_interface_ip_address
                  h
                end

                def length
                  @remote_interface_ip_address.flatten.size*4
                end

                def to_s
                  self.class.to_s + ": " + remote_interface_ip_address.join(", ")
                end

                def to_s_junos_style(ident=0)
                  s = "  "*ident + "RemIfAdr (4), length #{length}:"
                  s += remote_interface_ip_address.collect {|addr| "\n  #{"  "*ident}#{addr}"}.join
                end

              end


              =begin rdoc

              2.5.5.  Traffic Engineering Metric

              The Traffic Engineering Metric sub-TLV specifies the link metric for
              traffic engineering purposes.  This metric may be different than the
              standard OSPF link metric.  Typically, this metric is assigned by a
              network administrator.

              The Traffic Engineering Metric sub-TLV is TLV type 5, and is four
              octets in length.

              =end


              class TE_MetricSubTLV < SubTLV
                include Ospf

                attr_reader :tlv_type, :length, :te_metric
                attr_writer :te_metric

                def initialize(arg={})
                  @tlv_type, @length, @te_metric = 5,4,0
                  if arg.is_a?(Hash) then
                    set(arg)
                  elsif arg.is_a?(String)
                    __parse(arg)
                  else
                    raise ArgumentError, "Invalid argument", caller
                  end
                end

                def te_metric=(arg)
                  @te_metric=arg[:te_metric] unless arg[:te_metric].nil?
                end

                def set(arg)
                  return self unless arg.is_a?(Hash)
                  self.te_metric=arg
                end

                def enc
                  __enc([
                    [@tlv_type,  'n'], 
                    [@length, 'n'], 
                    [@te_metric, 'N'], 
                    ])
                  end

                  def __parse(s)
                    arr = s.unpack('nnN')
                    @tlv_type = arr[0]
                    @length= arr[1]
                    @te_metric = arr[2]
                  end
                  private :__parse


                  def to_hash
                    h=super
                    h[:te_metric]=te_metric
                    h
                  end

                  def to_s
                    self.class.to_s + ": #{te_metric}"
                  end

                  def to_s_junos_style(ident=0)
                    "  "*ident + "TEMetric (5), length #{@length}:\n  #{"  "*ident}#{te_metric}"
                  end

                end

                =begin rdoc

                2.5.6.  Maximum Bandwidth

                The Maximum Bandwidth sub-TLV specifies the maximum bandwidth that
                can be used on this link, in this direction (from the system
                originating the LSA to its neighbor), in IEEE floating point format.
                This is the true link capacity.  The units are bytes per second.

                The Maximum Bandwidth sub-TLV is TLV type 6, and is four octets in
                length.

                =end


                class MaximumBandwidth_SubTLV < SubTLV
                  include Ospf

                  attr_reader :tlv_type, :length, :max_bw
                  attr_writer :max_bw

                  def initialize(arg={})
                    @tlv_type, @length, @max_bw = 6,4,0.0
                    if arg.is_a?(Hash) then
                      set(arg)
                    elsif arg.is_a?(String)
                      __parse(arg)
                    else
                      raise ArgumentError, "Invalid argument", caller
                    end
                  end

                  def max_bw=(arg)
                    @max_bw=arg[:max_bw] unless arg[:max_bw].nil?
                  end

                  def set(arg)
                    return self unless arg.is_a?(Hash)
                    self.max_bw=arg
                  end

                  def enc
                    __enc([
                      [@tlv_type,  'n'], 
                      [@length, 'n'], 
                      [@max_bw/8.0, 'g'], 
                      ])
                    end

                    def __parse(s)
                      arr = s.unpack('nng')
                      @tlv_type = arr[0]
                      @length= arr[1]
                      @max_bw = arr[2] * 8.0
                    end
                    private :__parse

                    def to_hash
                      h=super
                      h[:max_bw]=max_bw 
                      h
                    end

                    def to_s
                      self.class.to_s + ": #{max_bw}"
                    end

                    def to_s_junos_style(ident=0)
                      "  "*ident + "MaxBW (6), length #{@length}:\n  #{"  "*ident}#{bw_to_s(max_bw)}"
                    end

                  end


                  =begin rdoc
                  2.5.7.  Maximum Reservable Bandwidth

                  The Maximum Reservable Bandwidth sub-TLV specifies the maximum
                  bandwidth that may be reserved on this link, in this direction, in
                  IEEE floating point format.  Note that this may be greater than the
                  maximum bandwidth (in which case the link may be oversubscribed).
                    This SHOULD be user-configurable; the default value should be the
                    Maximum Bandwidth.  The units are bytes per second.

                    The Maximum Reservable Bandwidth sub-TLV is TLV type 7, and is four
                    octets in length.

                    =end


                    class MaximumReservableBandwidth_SubTLV < SubTLV
                      include Ospf

                      attr_reader :tlv_type, :length, :max_resv_bw
                      attr_writer :max_resv_bw

                      def initialize(arg={})
                        @tlv_type, @length, @max_resv_bw = 7,4,0.0
                        if arg.is_a?(Hash) then
                          set(arg)
                        elsif arg.is_a?(String)
                          __parse(arg)
                        else
                          raise ArgumentError, "Invalid argument", caller
                        end
                      end

                      def max_resv_bw=(arg)
                        # should be an array of 8 bw.
                        @max_resv_bw=arg[:max_resv_bw] unless arg[:max_resv_bw].nil?
                      end

                      def set(arg)
                        return self unless arg.is_a?(Hash)
                        self.max_resv_bw=arg
                      end

                      def enc
                        __enc([
                          [@tlv_type,  'n'], 
                          [@length, 'n'], 
                          [@max_resv_bw / 8, 'g'], 
                          ])
                        end

                        def __parse(s)
                          arr = s.unpack('nng')
                          @tlv_type = arr[0]
                          @length= arr[1]
                          @max_resv_bw = arr[2] * 8
                        end
                        private :__parse

                        def to_hash
                          h=super
                          h[:max_resv_bw]=max_resv_bw 
                          h
                        end

                        def to_s
                          self.class.to_s + ": #{max_resv_bw}"
                        end

                        def to_s_junos_style(ident=0)
                          "  "*ident + "MaxRsvBW (7), length #{@length}:\n  #{"  "*ident}#{bw_to_s(max_resv_bw)}"
                        end

                      end

                      =begin rdoc

                      2.5.8.  Unreserved Bandwidth

                      The Unreserved Bandwidth sub-TLV specifies the amount of bandwidth
                      not yet reserved at each of the eight priority levels in IEEE
                      floating point format.  The values correspond to the bandwidth that
                      can be reserved with a setup priority of 0 through 7, arranged in
                      increasing order with priority 0 occurring at the start of the sub-
                      TLV, and priority 7 at the end of the sub-TLV.  The initial values
                      (before any bandwidth is reserved) are all set to the Maximum
                      Reservable Bandwidth.  Each value will be less than or equal to the
                      Maximum Reservable Bandwidth.  The units are bytes per second.

                      The Unreserved Bandwidth sub-TLV is TLV type 8, and is 32 octets in
                      length.

                      =end

                      class UnreservedBandwidth_SubTLV < SubTLV
                        include Ospf

                        attr_reader :tlv_type, :unreserved_bw
                        attr_writer :unreserved_bw

                        def initialize(arg={})
                          @tlv_type, @length, @unreserved_bw = 8,4, []
                          if arg.is_a?(Hash) then
                            set(arg)
                          elsif arg.is_a?(String)
                            __parse(arg)
                          else
                            raise ArgumentError, "Invalid argument", caller
                          end
                        end

                        def length
                          @unreserved_bw.flatten.size*4
                        end

                        def unreserved_bw=(arg)
                          if arg.is_a?(Hash)
                            unless arg[:unreserved_bw].nil?
                              arg[:unreserved_bw].each { |bw|
                                @unreserved_bw << bw
                              }
                            end
                          elsif arg.is_a?(Array) and arg.size==8
                            @unreserved_bw = arg
                          end
                        end

                        def set(arg)
                          return self unless arg.is_a?(Hash)
                          self.unreserved_bw=arg
                        end

                        def enc
                          s = __enc([
                            [@tlv_type,  'n'], 
                            [length, 'n'], 
                            ])
                            s += @unreserved_bw.collect { |bw| bw / 8 }.pack('g*')        
                          end

                          def __parse(s)
                            arr = s.unpack('nng*')
                            @tlv_type = arr[0]
                            length= arr[1]
                            @unreserved_bw = arr[2..-1].collect {|bw| bw*8 }
                          end
                          private :__parse

                          def to_hash
                            h=super
                            h[:unreserved_bw] = unreserved_bw
                            h
                          end

                          def to_s
                            self.class.to_s + ": " + unreserved_bw.collect { |bw| bw }.join(", ")
                          end

                          def to_s_junos_style(ident=0)
                            s = "  "*ident + "UnRsvBW (8), length #{length}:"
                            unreserved_bw.each_with_index { |bw,i| s +="\n  #{"  "*ident}Priority #{i}, #{bw_to_s(bw)}" }
                            s
                          end    

                        end

                        =begin rdoc

                        The Traffic Engineering Color sub-TLV is TLV type 9, and is four
                        octets in length.

                        =end


                        class Color_SubTLV < SubTLV
                          include Ospf

                          attr_reader :tlv_type, :length, :color
                          attr_writer :color

                          def initialize(arg={})
                            @tlv_type, @length, @color = 9,4,0
                            if arg.is_a?(Hash) then
                              set(arg)
                            elsif arg.is_a?(String)
                              __parse(arg)
                            else
                              raise ArgumentError, "Invalid argument", caller
                            end
                          end

                          def color=(arg)
                            @te_metric=arg[:color] unless arg[:color].nil?
                          end

                          def set(arg)
                            return self unless arg.is_a?(Hash)
                            self.color=arg
                          end

                          def enc
                            __enc([
                              [@tlv_type,  'n'], 
                              [@length, 'n'], 
                              [@te_metric, 'N'], 
                              ])
                            end

                            def __parse(s)
                              arr = s.unpack('nnN')
                              @tlv_type = arr[0]
                              @length= arr[1]
                              @color = arr[2]
                            end
                            private :__parse

                            def to_hash
                              h=super
                              h[:color]=color
                              h
                            end

                            def to_s
                              self.class.to_s + ": #{color}"
                            end

                            def to_s_junos_style(ident=0)
                              "  "*ident + "Color (9), length #{@length}:\n  #{"  "*ident}#{color}"
                            end

                          end
                        end

                        if __FILE__ == $0
                          load '../test/opaque_tlvs_test.rb'
                        end

