require "test/unit"
require "ie/router_link"
require 'ie/router_link_factory'
class TestIeRouterLink < Test::Unit::TestCase
  include OSPFv2
  def tests
    assert RouterLink.new
    assert_equal '000000000000000001000000', RouterLink.new.to_shex
    assert_equal 4*3, RouterLink.new.encode.size
    assert_equal '', RouterLink.new.router_link_type.to_s
    assert_equal '010101010000000001000000', RouterLink.new( :link_id=> '1.1.1.1').to_shex
    assert_equal '01010101ffffffff01000000',
                  RouterLink.new( :link_id=> '1.1.1.1', :link_data=> '255.255.255.255').to_shex
    assert_equal '01010101ffffffff0100000a',
                RouterLink.new( :link_id=> '1.1.1.1', :link_data=> '255.255.255.255', :metric=>10).to_shex
    assert_equal '01010101ffffffff0101000a0a000014',
                RouterLink.new( :link_id=> '1.1.1.1', 
                                :link_data=> '255.255.255.255', 
                                :metric=>10, 
                                :mt_metrics =>{ :id=>10, :metric=>20}).to_shex
    assert_equal '01010101ffffffff0102000a0a0000140b00001e',
                RouterLink.new( :link_id=> '1.1.1.1', 
                                :link_data=> '255.255.255.255', 
                                :metric=>10, 
                                :mt_metrics => [{:id=>10, :metric=>20},{:id=>11, :metric=>30}]
                                ).to_shex
    
    assert_equal '010101010000000001000000', RouterLink.new(:link_id=> '1.1.1.1').to_shex
    assert_equal '000000000101010101000000', RouterLink.new(:link_data=> '1.1.1.1').to_shex
    assert_equal '020202020101010101000000', RouterLink.new(:link_data=> '1.1.1.1', :link_id=>'2.2.2.2').to_shex
    assert_equal '02020202010101010100000a', RouterLink.new(:link_data=> '1.1.1.1', :link_id=>'2.2.2.2', :metric=>10).to_shex
    assert_equal '02020202010101010101000a0a000014', 
          RouterLink.new(:link_data=> '1.1.1.1', :link_id=>'2.2.2.2', :metric=>10, :mt_metrics =>{ :id=>10, :metric=>20}).to_shex
    
    h = {
      :link_id=> '1.1.1.1', 
      :link_data=> '255.255.255.255', 
      :metric=>10, 
      :mt_metrics => [{:id=>10, :metric=>20},{:id=>11, :metric=>30}]
    }    
    assert_equal(h, RouterLink.new(h).to_hash)
    assert RouterLink::PointToPoint.new({})
    assert_equal '000000000000000001000000', RouterLink::PointToPoint.new({}).to_shex
    assert_equal '000000000000000003000000', RouterLink::StubNetwork.new({}).to_shex
    assert_equal '000000000000000004000000', RouterLink::VirtualLink.new({}).to_shex
    assert_equal '000000000000000002000000', RouterLink::TransitNetwork.new({}).to_shex
    assert_equal '010101010000000001000000', RouterLink::PointToPoint.new(:link_id=>'1.1.1.1').to_shex
    assert_equal '000000000202020203000000', RouterLink::StubNetwork.new(:link_data=>'2.2.2.2').to_shex
    assert_equal '00000000000000000400abcd', RouterLink::VirtualLink.new(:metric=>0xabcd).to_shex
    assert_equal '0000000000000000020100000a000014', 
          RouterLink::TransitNetwork.new(:mt_metrics =>{ :id=>10, :metric=>20}).to_shex
    
    assert_equal '000000000000000001000000', RouterLink.new(['000000000000000001000000'].pack('H*')).to_shex
    assert_equal '000000000000000003000000', RouterLink.new(['000000000000000003000000'].pack('H*')).to_shex
    assert_equal '000000000000000004000000', RouterLink.new(['000000000000000004000000'].pack('H*')).to_shex
    assert_equal '000000000000000002000000', RouterLink.new(['000000000000000002000000'].pack('H*')).to_shex
    assert_equal '0000000000000000020100000a000014', RouterLink.new(['0000000000000000020100000a000014'].pack('H*')).to_shex
    
  end
  
  def test_point_2_point
    
    
    
    # puts RouterLink::PointToPoint.new(:link_data=> '2.2.2.2', :link_id=>'1.1.1.1').to_s
    # puts RouterLink::PointToPoint.new(:link_data=> '2.2.2.2', :link_id=>'1.1.1.1').to_s_junos
    # puts RouterLink::PointToPoint.new(:link_data=> '2.2.2.2', :link_id=>'1.1.1.1').to_s_ios
    # 





  end
  
  
  
  def test_misc
    h = {:router_link_type=>3, :metric=>1, :link_data=>"255.255.255.240", :link_id=>"192.168.8.0"}
    assert_equal "c0a80800fffffff003000001", RouterLink.factory(h).to_shex
    h = {:router_link_type=>1, :metric=>1,:mt_metrics=>[{:id=>15, :metric=>14}, {:id=>13, :metric=>12}], :link_data=>"10.254.233.233",:link_id=>"2.2.2.2"}
    assert_equal "020202020afee9e9010200010f00000e0d00000c", RouterLink.factory(h).to_shex
  end
  
  def test_tos_metric
    h = {:router_link_type=>1, :metric=>1, :link_data=>"10.254.233.233",:link_id=>"2.2.2.2"}
    rlink = RouterLink.factory(h)
    rlink << [33,20]
    rlink << [34,255]
    assert_equal "020202020afee9e90102000121000014220000ff", rlink.to_shex
    rlink = RouterLink.new(h)
    rlink << MtMetric.new([33,20])
    rlink << MtMetric.new([34,255])
    assert_equal("020202020afee9e90102000121000014220000ff", rlink.to_shex)
    rlink = RouterLink.new(h)
    rlink << [33,20] << [34,255]
    assert_equal("020202020afee9e90102000121000014220000ff", rlink.to_shex)
    rlink = RouterLink.new(h)
    assert_raise(ArgumentError) { rlink << [33] }
    assert_raise(ArgumentError) { rlink << [33,100,1] }
  end
  
  def test_router_link_p2p
    h = {:metric=>1, :link_data=>"255.255.255.240", :link_id=>"192.168.8.0"}
    assert_equal "PointToPoint:\n    LinkId: 192.168.8.0\n    LinkData: 255.255.255.240\n    RouterLinkType: point_to_point\n    Metric: 1",
              RouterLink::PointToPoint.new(h).to_s
    assert_equal "c0a80800fffffff001000001", RouterLink::PointToPoint.new(h).to_shex
    assert_equal(:point_to_point, RouterLink::PointToPoint.new(h).to_hash[:router_link_type])
    assert_equal(1, RouterLink::PointToPoint.new(h).to_hash[:metric])
    assert_equal("255.255.255.240", RouterLink::PointToPoint.new(h).to_hash[:link_data])
    assert_equal("192.168.8.0", RouterLink::PointToPoint.new(h).to_hash[:link_id])
    assert_equal( RouterLink::PointToPoint.new(h).encode, RouterLink::PointToPoint.new( RouterLink::PointToPoint.new(h)).encode)
  end
  
  def test_new_from_hash
    h = {:metric=>1, :link_data=>"255.255.255.240", :link_id=>"192.168.8.0"}
    assert_equal RouterLink::PointToPoint, RouterLink.new_point_to_point(h).class
    assert_equal RouterLink::StubNetwork, RouterLink.new_stub_network(h).class
    assert_equal RouterLink::TransitNetwork, RouterLink.new_transit_network(h).class
    assert_equal RouterLink::VirtualLink, RouterLink.new_virtual_link(h).class
  end
  
  def test_to_s
    h = {:metric=>1, :link_data=>"255.255.255.240", :link_id=>"192.168.8.0",
      :mt_metrics => [{:id=>10, :metric=>20},{:id=>11, :metric=>30}]}
    assert_match( /PointToPoint:\n    LinkId: 192.168.8.0\n/  ,RouterLink.new_point_to_point(h).to_s)
    assert_match( /LinkData: 255.255.255.240\n/,RouterLink.new_point_to_point(h).to_s)
    assert_match( /RouterLinkType: point_to_point\n    Metric: 1/,RouterLink.new_point_to_point(h).to_s)
  end
  
  # id 0.0.0.2, data 192.168.2.1, Type PointToPoint (1)
  #   Topology count: 0, Default metric: 2
  # id 192.168.2.0, data 255.255.255.0, Type Stub (3)
  #   Topology count: 0, Default metric: 2
  # id 0.0.0.3, data 192.168.3.1, Type PointToPoint (1)
  #   Topology count: 0, Default metric: 2
  # id 192.168.3.0, data 255.255.255.0, Type Stub (3)
  #   Topology count: 0, Default metric: 2
  # id 0.0.0.4, data 192.168.4.1, Type PointToPoint (1)
  #   Topology count: 0, Default metric: 2
  # id 192.168.4.0, data 255.255.255.0, Type Stub (3)
  #   Topology count: 0, Default metric: 2
  # 
  def test_to_s_junos
    h_link1 = {:router_link_type=>1, :metric=>1, :link_data=>"255.255.255.240", :link_id=>"192.168.8.0"}
    h_link2 = {:router_link_type=>2, :metric=>1, :link_data=>"255.255.255.240", :link_id=>"192.168.8.0"}
    h_link3 = {:router_link_type=>3, :metric=>1, :link_data=>"255.255.255.240", :link_id=>"192.168.8.0"}
    assert_equal("  id 192.168.8.0, data 255.255.255.240, Type Point-to-point (1)\n    Topology count: 0, Default metric: 1", RouterLink.new(h_link1).to_s_junos)
    assert_equal("  id 192.168.8.0, data 255.255.255.240, Type Transit (2)\n    Topology count: 0, Default metric: 1", RouterLink.new(h_link2).to_s_junos)
    assert_equal("  id 192.168.8.0, data 255.255.255.240, Type Stub (3)\n    Topology count: 0, Default metric: 1", RouterLink.new(h_link3).to_s_junos)
    h = {
       :router_link_type => 2,
       :link_id=> '1.1.1.1', 
       :link_data=> '255.255.255.255', 
       :metric=>10, 
       :mt_metrics => [{:id=>10, :metric=>20},{:id=>11, :metric=>30}]
     }    
     
     # puts ""
     # puts RouterLink.new(h).to_s_junos
     assert_equal("  id 1.1.1.1, data 255.255.255.255, Type Transit (2)\n    Topology count: 2, Default metric: 10\n    Topology 10, Metric 20\n    Topology 11, Metric 30", RouterLink.new(h).to_s_junos)
  end
  

end

__END__



            OSPF Router with ID (1.1.1.1) (Process ID 1)

                Router Link States (Area 0)

  LS age: 1701
  Options: (No TOS-capability, DC)
  LS Type: Router Links
  Link State ID: 1.1.1.1
  Advertising Router: 1.1.1.1
  LS Seq Number: 80000015
  Checksum: 0xEEBC
  Length: 84
  Number of Links: 5

    Link connected to: another Router (point-to-point)
     (Link ID) Neighboring Router ID: 0.0.0.1
     (Link Data) Router Interface address: 192.168.158.13
      Number of TOS metrics: 0
       TOS 0 Metrics: 1

    Link connected to: a Stub Network
     (Link ID) Network/subnet number: 192.168.158.0
     (Link Data) Network Mask: 255.255.255.0
      Number of TOS metrics: 0
       TOS 0 Metrics: 1

    Link connected to: a Transit Network
     (Link ID) Designated Router address: 192.168.0.2
     (Link Data) Router Interface address: 192.168.0.1
      Number of TOS metrics: 0
       TOS 0 Metrics: 10

    Link connected to: a Stub Network
     (Link ID) Network/subnet number: 20.0.0.3
     (Link Data) Network Mask: 255.255.255.255
      Number of TOS metrics: 0
       TOS 0 Metrics: 1

    Link connected to: a Stub Network
     (Link ID) Network/subnet number: 20.0.0.1
     (Link Data) Network Mask: 255.255.255.255
      Number of TOS metrics: 0
       TOS 0 Metrics: 1


R1#



LS age: 22
Options:  0x22  [DC,E]
LS Type: Router Links
Link State ID: 1.1.1.1
Advertising Router: 1.1.1.1
LS Seq Number: 80000019
Checksum: 0xE6C0
Length: 84
Number of Links: 5

  Link connected to: another Router (point-to-point)
    (Link ID) Neighboring Router ID: 0.0.0.1
    (Link Data) Router Interface address: 192.168.158.13
  
   
  Link connected to: a Stub Network
    (Link ID) Network/subnet number: 192.168.158.0
    (Link Data) Network Mask: 255.255.255.0
  
   
  Link connected to: a Transit Network
    (Link ID) Designated Router address: 192.168.0.2
    (Link Data) Router Interface address: 192.168.0.1
  
   
  Link connected to: a Stub Network
    (Link ID) Network/subnet number: 20.0.0.3
    (Link Data) Network Mask: 255.255.255.255
  
   
  Link connected to: a Stub Network
    (Link ID) Network/subnet number: 20.0.0.1
    (Link Data) Network Mask: 255.255.255.255
  




    LS Seq Number: 80000001
    Checksum: 0xEC8D
    Length: 72
    Number of Links: 4

      Link connected to: another Router (point-to-point)
        (Link ID) Neighboring Router ID: 1.1.1.1
        (Link Data) Router Interface address: 192.168.158.1
         Number of TOS metrics: 0
         TOS 0 Metrics: 1


      Link connected to: a Stub Network
        (Link ID) Network/subnet number: 192.168.158.1
        (Link Data) Network Mask: 255.255.255.255
         Number of TOS metrics: 0
         TOS 0 Metrics: 1


