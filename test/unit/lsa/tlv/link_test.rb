require "test/unit"

require "lsa/tlv/link"
require 'lsa/tlv/tlv_factory'

class TestLsaTlvLink < Test::Unit::TestCase
  include OSPFv2
  def test_new

     link_tlv = Link_Tlv.new
     assert_equal('00020000', link_tlv.to_shex)

     link_tlv << LinkType_Tlv.new
     assert_equal('000200080001000101000000', link_tlv.to_shex)

     link_tlv << LinkId_Tlv.new(:link_id=>'1.2.3.4')
     assert_equal('0002001000010001010000000002000401020304', link_tlv.to_shex)

     link_tlv << LocalInterfaceIpAddress_Tlv.new(:ip_address=>"1.1.1.1")
     assert_equal('00020018000100010100000000020004010203040003000401010101', link_tlv.to_shex)

     link_tlv << RemoteInterfaceIpAddress_Tlv.new(:ip_address=>"2.2.2.2")
     assert_equal('000200200001000101000000000200040102030400030004010101010004000402020202', link_tlv.to_shex)

     link_tlv << TrafficEngineeringMetric_Tlv.new(:te_metric=>255)
     s  = '0002002800010001010000000002000401020304'
     s +='0003000401010101000400040202020200050004000000ff'
     assert_equal(s, link_tlv.to_shex)

     link_tlv << MaximumBandwidth_Tlv.new(:max_bw=>100_000_000)
     s  = '0002003000010001010000000002000401020304'
     s += '0003000401010101000400040202020200050004000000ff'
     s += '000600044b3ebc20'
     assert_equal(s, link_tlv.to_shex)
     
     link_tlv << MaximumReservableBandwidth_Tlv.new(:max_resv_bw=>100_000_000)
    s  = '000200380001000101000000'
    s += '0002000401020304'
    s += '0003000401010101'
    s += '0004000402020202'
    s += '00050004000000ff'
    s += '000600044b3ebc20'
    s += '000700044b3ebc20'
assert_equal(s, link_tlv.to_shex)
     link_tlv << UnreservedBandwidth_Tlv.new(:unreserved_bw=>[100_000_000]*8)
     s = '0002 005c 
         0001 0001 01 000000 
         0002 0004 01020304   
         0003 0004 01010101 
         0004 0004 02020202 
         0005 0004 000000ff 
         000600044b3ebc20
         000700044b3ebc20
         0008 0020 4b3ebc20 4b3ebc20 4b3ebc20 4b3ebc20 4b3ebc20 4b3ebc20 4b3ebc20 4b3ebc20' 
     assert_equal(s.split.join, link_tlv.to_shex)
     
     puts link_tlv
  end
  def test_tlv_type_6
    link_type = SubTlv.factory(['0006 0004 4b3e bc20'.split.join].pack('H*'))
    assert_equal(MaximumBandwidth_Tlv,link_type.class) 
    assert_equal(100000000.0,link_type.max_bw) 
    assert_equal({:tlv_type=>6, :max_bw=>100000000},link_type.to_hash) 
    assert_equal('000600044b3ebc20', SubTlv.factory({:tlv_type=>6, :max_bw=>100_000_000.0}).to_shex) 
    assert_equal(MaximumBandwidth_Tlv,link_type.class) 
    assert_equal(100000000.0,link_type.max_bw)  
  end  
  def test_tlv_type_7
    link_type = SubTlv.factory(['0007 0004 4b3e bc20'.split.join].pack('H*'))
    assert_equal(MaximumReservableBandwidth_Tlv,link_type.class) 
    assert_equal('Maximum reservable bandwidth : 100000000',link_type.to_s) 
    assert_equal({:tlv_type=>7, :max_resv_bw=>100000000},link_type.to_hash) 
    assert_equal('000700044b3ebc20', SubTlv.factory({:tlv_type=>7, :max_resv_bw=>100000000}).to_shex) 


    assert_equal(100000000.0, link_type.max_resv_bw)
  end
  
  def test_tlv_type_8
    link_type =  SubTlv.factory(['0008 0020 4b3e bc20 4b3e bc20 4b3e bc20 4b3e bc20 4b3e bc20 4b3e bc20 4b3e bc20 4b3e bc20 '.split.join].pack('H*'))
    assert_equal(100000000.0, link_type.unreserved_bw[0]) 
    link_type = SubTlv.factory(['0008 0020 4b94 50c0
		 4b94 50c0 4b94 50c0 4b94 50c0 4b94 50c0
		 4b94 50c0 4b94 50c0 4b94 50c0 '.split.join].pack('H*'))
     assert_equal(8,link_type.tlv_type) 
     assert_equal(UnreservedBandwidth_Tlv,link_type.class) 
    assert_equal(155520000.0, link_type.unreserved_bw[0])
    assert_equal("Unreserved bandwidth : 155520000, 155520000, 155520000, 155520000, 155520000, 155520000, 155520000, 155520000", link_type.to_s) 
  end
  
end


__END__


__END__


TODO: to_s_ios

                Type-10 Opaque Link Area Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum Opaque ID
1.0.0.0         0.0.0.3         23          0x80000001 0x000D12 0       
1.0.0.255       0.0.0.1         23          0x80000001 0x00ACB1 255     




R1#show ip ospf database opaque-area 

            OSPF Router with ID (1.1.1.1) (Process ID 1)

                Type-10 Opaque Link Area Link States (Area 0)

  LS age: 44
  Options: (No TOS-capability, No DC)
  LS Type: Opaque Area Link
  Link State ID: 1.0.0.0
  Opaque Type: 1
  Opaque ID: 0
  Advertising Router: 0.0.0.3
  LS Seq Number: 80000001
  Checksum: 0xD12
  Length: 116
  Fragment number : 0

    Link connected to Point-to-Point network
      Link ID : 5.6.7.8
      Interface Address : 111.111.111.111
      Neighbor Address : 222.222.222.222
      Admin Metric : 255
      Maximum bandwidth : 1250
      Maximum reservable bandwidth : 875
      Number of Priority : 8
      Priority 0 : 12          Priority 1 : 12        
      Priority 2 : 12          Priority 3 : 12        
      Priority 4 : 12          Priority 5 : 12        
      Priority 6 : 12          Priority 7 : 12        

    Number of Links : 1

  LS age: 45
  Options: (No TOS-capability, No DC)
  LS Type: Opaque Area Link
  Link State ID: 1.0.0.255
  Opaque Type: 1
  Opaque ID: 255
  Advertising Router: 0.0.0.1
  LS Seq Number: 80000001
  Checksum: 0xACB1
  Length: 116
  Fragment number : 255

    Link connected to Point-to-Point network
      Link ID : 1.2.3.4
      Interface Address : 1.1.1.1
      Neighbor Address : 2.2.2.2
      Admin Metric : 255
      Maximum bandwidth : 1250
      Maximum reservable bandwidth : 875
      Number of Priority : 8
      Priority 0 : 12          Priority 1 : 12        
      Priority 2 : 12          Priority 3 : 12        
      Priority 4 : 12          Priority 5 : 12        
      Priority 4 : 12          Priority 5 : 12        
      Priority 6 : 12          Priority 7 : 12        

    Number of Links : 1

  LS age: 45
  Options: (No TOS-capability, No DC)
  LS Type: Opaque Area Link
  Link State ID: 1.0.0.255
  Opaque Type: 1
  Opaque ID: 255
  Advertising Router: 0.0.0.1
  LS Seq Number: 80000001
  Checksum: 0xACB1
  Length: 116
  Fragment number : 255

    Link connected to Point-to-Point network
      Link ID : 1.2.3.4
      Interface Address : 1.1.1.1
      Neighbor Address : 2.2.2.2
      Admin Metric : 255
      Maximum bandwidth : 1250
      Maximum reservable bandwidth : 875
      Number of Priority : 8
      Priority 0 : 12          Priority 1 : 12        
      Priority 2 : 12          Priority 3 : 12        
      Priority 4 : 12          Priority 5 : 12        
      Priority 6 : 12          Priority 7 : 12        

    Number of Links : 1

R1#


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
