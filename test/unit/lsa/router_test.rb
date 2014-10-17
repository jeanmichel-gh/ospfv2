require "test/unit"

require "lsa/router"
require "lsa/lsa_factory"

class TestLsaRouter < Test::Unit::TestCase
  include OSPFv2
  def setup
    @rlsa = Router.new()
    @rlsa << @rlink1  = RouterLink.new_point_to_point(:link_id=>'1.1.1.1', :link_data=>'255.255.255.255', :metric=>11)
    @rlsa << @rlink2  = RouterLink.new_point_to_point(:link_id=>'1.1.1.2', :link_data=>'255.255.255.255', :metric=>12)
    @rlsa << @rlink22 = RouterLink.new_point_to_point(:link_id=>'1.1.1.2', :link_data=>'255.255.255.255', :metric=>122)
    @rlsa << @rlink3  = RouterLink.new_point_to_point(:link_id=>'1.1.1.3', :link_data=>'255.255.255.255', :metric=>13)
    @rlsa << @rlink4  = RouterLink.new_transit_network(:link_id=>'1.1.1.4', :link_data=>'255.255.255.255', :metric=>14)
    @rlsa << @rlink5  = RouterLink.new_point_to_point(:link_id=>'1.1.1.5', :link_data=>'255.255.255.255', :metric=>15)
  end
  
  def test_init_RouterLink
    _link1 = {:router_link_type=>1, :metric=>1, :link_data=>"255.255.255.240", :link_id=>"192.168.8.0"}
    _link2 = {:router_link_type=>2, :metric=>1, :link_data=>"255.255.255.240", :link_id=>"192.168.8.0"}
    _link3 = {:router_link_type=>3, :metric=>1, :link_data=>"255.255.255.240", :link_id=>"192.168.8.0"}
    _link =  {:router_link_type=>3, :metric=>1, :link_data=>"255.255.255.240", :link_id=>"192.168.8.0"}

    assert_equal("RouterLink:\n    LinkId: 192.168.8.0\n    LinkData: 255.255.255.240\n    RouterLinkType: stub_network\n    Metric: 1", RouterLink.new(_link3).to_s)
    assert_equal("c0a80800fffffff003000001", RouterLink.new(_link3).to_shex)
    assert_equal(:stub_network, RouterLink.new(_link3).to_hash[:router_link_type])
    assert_equal(1, RouterLink.new(_link3).to_hash[:metric])
    assert_equal("255.255.255.240", RouterLink.new(_link3).to_hash[:link_data])
    assert_equal("192.168.8.0", RouterLink.new(_link3).to_hash[:link_id])
    link = RouterLink.new(_link3)
    assert_equal(link.encode, RouterLink.new(link.encode).encode)
    assert_equal(:transit_network, RouterLink.new(_link2).to_hash[:router_link_type])
    assert_equal(:point_to_point, RouterLink.new(_link1).to_hash[:router_link_type])
  end
  
  def tests
    assert Router.new
    assert_equal '000000010000000000000000800000019dc7001800000000', Router.new.to_shex
    
    rlsa = Router.new :advertising_router => '1.1.1.1', :link_id => '2.2.2.2'
    
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.1', :link_data=>'255.255.255.255', :metric=>11)
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.2', :link_data=>'255.255.255.255', :metric=>12)
    
    r = Router.new_ntop(rlsa.encode)
    assert_equal rlsa.to_shex, r.to_shex
    assert_equal OSPFv2::Router, r.class
    assert_equal '1.1.1.1', rlsa.to_hash[:advertising_router]
 end
  
  def test_nwveb
    r = Router.new :link_id=> '1.0.0.0', :link_data=> '255.255.255.0'
    rl = RouterLink::StubNetwork.new(:link_data=>'2.2.2.2')
    r << RouterLink::StubNetwork.new(:link_data=>'2.2.2.2')
    r << RouterLink::PointToPoint.new(:link_data=>'2.2.2.2', :link_id=>'1.1.1.1', :metric=>255)
    assert_equal 0, r.nwveb
    
    r.set_abr
    assert   r.abr?
    assert ! r.asbr?
    assert ! r.vl?
    assert ! r.wild?
    assert ! r.nssa?
    assert_equal 1, r.nwveb
    # puts r
    
    r.set_asbr
    assert   r.abr?
    assert   r.asbr?
    assert ! r.vl?
    assert ! r.wild?
    assert ! r.nssa?
    assert_equal 3, r.nwveb
    # puts r
    
    r.set_vl
    r.unset_abr
    assert ! r.abr?
    assert   r.asbr?
    assert   r.vl?
    assert ! r.wild?
    assert ! r.nssa?
    assert_equal 6, r.nwveb
    # puts r
    
    r.set_wild
    r.unset_asbr
    assert ! r.abr?
    assert ! r.asbr?
    assert   r.vl?
    assert   r.wild?
    assert ! r.nssa?
    assert_equal 12, r.nwveb
    
    r.set_nssa
    r.unset_vl
    assert ! r.abr?
    assert ! r.asbr?
    assert ! r.vl?
    assert   r.wild?
    assert   r.nssa?
    assert_equal 24, r.nwveb
    
    r.unset_wild
    r.unset_nssa
    assert_equal 0, r.nwveb
    
  end


  def _test_hash
   
    
    
    
  end


  def test_args_to_key
    assert_equal [1,'1.1.1.3'], @rlsa.args_to_key(:point_to_point, '1.1.1.3')
    assert_equal [1,'1.1.1.3'], @rlsa.args_to_key(1,'1.1.1.3')    
    assert_equal [1,'1.1.1.3'], @rlsa.args_to_key(@rlsa.links[3])
  end
  
  def test_index
    assert_equal 'Metric: 13', @rlsa[1,'1.1.1.3'].metric.to_s
  end
  
  def test_has?
    assert   @rlsa.has_link?(:point_to_point,'1.1.1.3')
    assert ! @rlsa.has_link?(:point_to_point,'1.1.1.4')
    assert   @rlsa.has_link?(2,'1.1.1.4')
    assert ! @rlsa.has_link?(:stub_network,'9.9.9.9')
  end
  
  def test_delete_link
     rlsa = Router.new()
     rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.1', :link_data=>'255.255.255.255', :metric=>11)
     rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.2', :link_data=>'255.255.255.255', :metric=>12)
     rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.2', :link_data=>'255.255.255.255', :metric=>122)
     rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.3', :link_data=>'255.255.255.255', :metric=>13)
     rlsa << RouterLink.new_transit_network(:link_id=>'1.1.1.4', :link_data=>'255.255.255.255', :metric=>14)
     rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.5', :link_data=>'255.255.255.255', :metric=>15)
     rlsa << RouterLink.new_stub_network(:link_id=>'192.168.0.0', :link_data=>'255.255.255.0', :metric=>15)
     assert_equal 7, rlsa.links.size
     assert rlsa.has_link?(:transit_network,'1.1.1.4')
     assert rlsa.has_link?(2,'1.1.1.4')
     rlsa.delete(2,'1.1.1.4')
     assert ! rlsa.has_link?(2,'1.1.1.4')
     assert_equal 6, rlsa.links.size
     rlsa.delete(:point_to_point,'1.1.1.1')
     assert ! rlsa.has_link?(1,'1.1.1.1')
     assert_equal 5, rlsa.links.size
  end

  def test_lookup
    rlsa = Router.new()
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.1', :link_data=>'255.255.255.255', :metric=>11)
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.2', :link_data=>'255.255.255.255', :metric=>12)
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.2', :link_data=>'255.255.255.255', :metric=>122)
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.3', :link_data=>'255.255.255.255', :metric=>13)
    rlsa << RouterLink.new_transit_network(:link_id=>'1.1.1.4', :link_data=>'255.255.255.255', :metric=>14)
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.5', :link_data=>'255.255.255.255', :metric=>15)
    rlsa << RouterLink.new_stub_network(:link_id=>'192.168.0.0', :link_data=>'255.255.255.0', :metric=>15)
    
    # puts rlsa
    # puts rlsa.to_s_junos
    
    assert rlsa.lookup(1,'1.1.1.1')
    assert rlsa.lookup(:point_to_point,'1.1.1.1')
    assert_equal RouterLink::PointToPoint, rlsa.lookup(1,'1.1.1.1').class
    assert rlsa.lookup(1,'1.1.1.1')
    assert rlsa[:point_to_point,'1.1.1.1']
    assert rlsa[1,'1.1.1.1']
    assert ! rlsa.lookup(2,'1.1.1.1')
    
    assert rlsa.lookup(3,'192.168.0.0')
    assert rlsa.lookup(:stub_network,'192.168.0.0')
    assert rlsa[:stub_network,'192.168.0.0']
    assert rlsa[3,'192.168.0.0']
    assert ! rlsa[1,'192.168.0.0']
    
  end

  def test_lookup
    rlsa = Router.new()
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.1', :link_data=>'255.255.255.255', :metric=>11)
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.2', :link_data=>'255.255.255.255', :metric=>12)
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.2', :link_data=>'255.255.255.255', :metric=>122)
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.3', :link_data=>'255.255.255.255', :metric=>13)
    rlsa << RouterLink.new_transit_network(:link_id=>'1.1.1.4', :link_data=>'255.255.255.255', :metric=>14)
    rlsa << RouterLink.new_point_to_point(:link_id=>'1.1.1.5', :link_data=>'255.255.255.255', :metric=>15)
    rlsa << RouterLink.new_stub_network(:link_id=>'192.168.0.0', :link_data=>'255.255.255.0', :metric=>15)
    
    assert_equal 7, rlsa.links.size
    assert rlsa.lookup(1,'1.1.1.1')
    rlsa.delete(rlsa.lookup(:point_to_point,'1.1.1.1'))
    assert_equal 6, rlsa.links.size
    rlsa.delete(rlsa.lookup(:point_to_point,'1.1.1.2'))
    assert_equal 4, rlsa.links.size
    rlsa.delete(rlsa.lookup(:point_to_point,'1.1.1.3'))
    rlsa.delete(rlsa.lookup(:point_to_point,'1.1.1.5'))
    assert_equal 2, rlsa.links.size
    
  end
  
end

__END__


class RouterLSA_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  
    
    assert_equal(6, lsa.links.size)
    assert_equal(Array, lsa.links.class)
    assert_equal("10.255.8.6", lsa.to_hash[:lsid])
    assert_equal("10.255.8.6", lsa.to_hash[:advr])
    assert_equal(0x22, lsa.to_hash[:options])
    assert_equal(0x8000016b, lsa.to_hash[:seqn])
    assert_equal(0xe3f5, lsa.to_hash[:csum])
    link = lsa.lookup(3,'10.254.241.0')
    assert_match(/type: stub  id: 10.254.241.0/,link.to_s)
  end
  def test_init_RouterLink_mt_id
    rlsa = "
    00 01 22 01 0a ff 08 02 0a ff 08 02 80 00 00 03
    99 c4 00 40 00 00 00 02 02 02 02 02 0a fe e9 e9
    01 02 00 01 21 00 00 14 22 00 00 ff 0a fe e9 00
    ff ff ff 00 03 02 00 01 21 00 00 14 22 00 00 ff
    "
    lsa  = Ospf::RouterLSA.new([rlsa.split.join].pack('H*'))
    
    assert_match(/bits 0x0, link count 2\n\s*id 2.2.2.2, data 10.254.233.233, Type Point-to-point \(1\)\n\s*Topology /,lsa.to_s_junos_style(:detailed))
    
    assert_equal(rlsa.split.join, lsa.to_shex)
    assert_equal(2, lsa.links.size)
    assert_equal("10.255.8.2", lsa.to_hash[:lsid])
    assert_equal("10.255.8.2", lsa.to_hash[:advr])
    assert_equal(0x22, lsa.to_hash[:options])
    assert_equal(0x80000003, lsa.to_hash[:seqn])
    assert_equal(0x99c4, lsa.to_hash[:csum])

    assert_equal(33,lsa.to_hash[:links][0][:mt_id][0][:id])
    assert_equal(34,lsa.to_hash[:links][0][:mt_id][1][:id])
    assert_equal(20,lsa.to_hash[:links][0][:mt_id][0][:metric])
    assert_equal(255,lsa.to_hash[:links][0][:mt_id][1][:metric])

  end
  def test_nwveb
    lsa = Ospf::RouterLSA.new()
    lsa.setABR
    assert_equal(1, lsa.to_hash[:nwveb])
    lsa.setVL
    assert_equal(5, lsa.to_hash[:nwveb])
    lsa.setASBR
    assert_equal(7, lsa.to_hash[:nwveb])
    lsa.setWr
    assert_equal(15, lsa.to_hash[:nwveb])
    lsa.setNt
    assert_equal(31, lsa.to_hash[:nwveb])
    lsa.setABR
    lsa.setVL
    lsa.setASBR
    lsa.setNt
    lsa.setWr
    assert_equal(true,lsa.isWr?)
    assert_equal(true,lsa.isNt?)
    assert_equal(true,lsa.isABR?)
    assert_equal(true,lsa.isASBR?)
    assert_equal(true,lsa.isVL?)

    assert_equal(31, lsa.to_hash[:nwveb])
    lsa.unsetNt
    assert_equal(15, lsa.to_hash[:nwveb])
    lsa.unsetWr
    assert_equal(7, lsa.to_hash[:nwveb])
    lsa.unsetABR
    assert_equal(6, lsa.to_hash[:nwveb])
    lsa.unsetVL
    assert_equal(2, lsa.to_hash[:nwveb])
    lsa.unsetASBR
    assert_equal(0, lsa.to_hash[:nwveb])
    assert_equal(false,lsa.isABR?)
    assert_equal(false,lsa.isASBR?)
    assert_equal(false,lsa.isVL?)

    lsa.unsetABR
    lsa.unsetVL
    lsa.unsetASBR
    assert_equal(0, lsa.to_hash[:nwveb])
  end

  def test_has?
    assert   @rlsa.has?(:point_to_point,'1.1.1.3')
    assert ! @rlsa.has?(:stub_network,'9.9.9.9'))
  end


  # def test_add
  #   rlsa = RouterLSA.new()
  #   rlsa << rlink1 = RouterLink.p2p({:id=>'1.1.1.1', :data=>'255.255.255.255', :metric=>11,})
  #   assert_equal(false, rlsa.has?(1,'2.2.2.2'))
  #   assert_equal(1,rlsa.links.compact.size)
  #   rlsa << {:id=>'2.2.2.2', :data=>'255.255.255.255', :metric=>11, :type=>1}
  #   assert_equal(2,rlsa.links.compact.size)
  #   rlsa << {:id=>'2.2.2.2', :data=>'255.255.255.255', :metric=>11, :type=>1}
  #   assert_equal(3,rlsa.links.compact.size)
  # end

end




require 'test/unit'
require 'pp'
require 'lsa_router'

class LSA_RouterLinkTest < Test::Unit::TestCase # :nodoc:
  include Ospf
  def setup
    @rlink1 = RouterLink.p2p({:id=>'1.1.1.1', :data=>'255.255.255.255', :metric=>11,})
    @rlink2 = RouterLink.p2p({:id=>'1.1.1.2', :data=>'255.255.255.255', :metric=>12,})
    @rlink3 = RouterLink.p2p({:id=>'1.1.1.3', :data=>'255.255.255.255', :metric=>13,})
    @rlink4 = RouterLink.p2p({:id=>'1.1.1.4', :data=>'255.255.255.255', :metric=>14,})
    @rlink5 = RouterLink.p2p({:id=>'1.1.1.5', :data=>'255.255.255.255', :metric=>15,})
  end
  def test_init_RouterLink_Factory_hash
    _link1 = {:type=>1, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    _link2 = {:type=>2, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    _link3 = {:type=>3, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    _link4 = {:type=>4, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    assert_match(/LinkP2P$/, RouterLink_Factory.create(_link1).class.to_s)
    assert_match(/LinkTransit$/, RouterLink_Factory.create(_link2).class.to_s)
    assert_match(/LinkStub$/, RouterLink_Factory.create(_link3).class.to_s)
    assert_match(/LinkVL$/, RouterLink_Factory.create(_link4).class.to_s)
    assert_raise(ArgumentError) { RouterLink_Factory.create({:id=>'2.2.2.2', :data=>'255.255.255.255', :metric=>11,}) }
  end
  def test_init_RouterLink_Factory_string
    _link1 = {:type=>1, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    _link2 = {:type=>2, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    _link3 = {:type=>3, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    _link4 = {:type=>4, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    slink1 = RouterLink.new(_link1).enc
    slink2 = RouterLink.new(_link2).enc
    slink3 = RouterLink.new(_link3).enc
    slink4 = RouterLink.new(_link4).enc
    assert_match(/LinkP2P$/, RouterLink_Factory.create(slink1).class.to_s)
    assert_match(/LinkTransit$/, RouterLink_Factory.create(slink2).class.to_s)
    assert_match(/LinkStub$/, RouterLink_Factory.create(slink3).class.to_s)
    assert_match(/LinkVL$/, RouterLink_Factory.create(slink4).class.to_s)
  end
  def test_init_RouterLink
    _link1 = {:type=>1, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    _link2 = {:type=>2, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    _link3 = {:type=>3, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    _link = {:type=>3, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    assert_equal("type: stub  id: 192.168.8.0  data: 255.255.255.240  metric: 1", RouterLink.new(_link3).to_s)
    assert_equal("c0a80800fffffff003000001", RouterLink.new(_link3).to_shex)
    assert_equal(3, RouterLink.new(_link3).to_hash[:type])
    assert_equal(1, RouterLink.new(_link3).to_hash[:metric])
    assert_equal("255.255.255.240", RouterLink.new(_link3).to_hash[:data])
    assert_equal("192.168.8.0", RouterLink.new(_link3).to_hash[:id])
    link = RouterLink.new(_link3)
    assert_equal(link.enc, RouterLink.new(link.enc).enc)
    assert_equal(2, RouterLink.new(_link2).to_hash[:type])
    assert_equal(1, RouterLink.new(_link1).to_hash[:type])
  end

  def test_RouterLink_to_s_junos_style
    _link1 = {:type=>1, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    _link2 = {:type=>2, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    _link3 = {:type=>3, :metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    assert_equal("  id 192.168.8.0, data 255.255.255.240, Type Point-to-point (1)\n    Topology count: 0, Default metric: 1", RouterLink.new(_link1).to_s_junos_style)
    assert_equal("  id 192.168.8.0, data 255.255.255.240, Type Transit (2)\n    Topology count: 0, Default metric: 1", RouterLink.new(_link2).to_s_junos_style)
    assert_equal("  id 192.168.8.0, data 255.255.255.240, Type Stub (3)\n    Topology count: 0, Default metric: 1", RouterLink.new(_link3).to_s_junos_style)
  end

  def test_init_RouterLink_mt
    _link1 = {:type=>1, :metric=>1,:mt_id=>[{:metric=>20, :id=>33}, {:metric=>255, :id=>34}], :data=>"10.254.233.233",:id=>"2.2.2.2"}
    _link2 = {:type=>3, :metric=>1,:mt_id=>[{:metric=>20, :id=>33}, {:metric=>255, :id=>34}], :data=>"255.255.255.0", :id=>"10.254.233.0"}
    _link3 = {:type=>1, :metric=>1,:mt_id=>[[33,20],[34,255]], :data=>"10.254.233.233",:id=>"2.2.2.2"}
    _link4 = {:type=>1, :metric=>1, :data=>"10.254.233.233",:id=>"2.2.2.2"}
    assert_equal(33, RouterLink.new(_link1).to_hash[:mt_id][0][:id])
    assert_equal(20, RouterLink.new(_link1).to_hash[:mt_id][0][:metric])

    assert_equal("020202020afee9e90102000121000014220000ff", RouterLink.new(_link1).to_shex)
    assert_equal("020202020afee9e90102000121000014220000ff", RouterLink.new(RouterLink.new(_link1).enc).to_shex)      
    assert_equal("020202020afee9e90102000121000014220000ff", RouterLink.new(RouterLink.new(_link3).enc).to_shex)      
  
    rlink = RouterLink.new(_link4)
    rlink << [33,20]
    rlink << [34,255]
    assert_equal("020202020afee9e90102000121000014220000ff", rlink.to_shex)      
    
    rlink = RouterLink.new(_link4)
    rlink << MT.new([33,20])
    rlink << MT.new([34,255])
    assert_equal("020202020afee9e90102000121000014220000ff", rlink.to_shex)      
    rlink = RouterLink.new(_link4)
    rlink << [33,20] << [34,255]
    assert_equal("020202020afee9e90102000121000014220000ff", rlink.to_shex)      
    rlink = RouterLink.new(_link4)
    assert_raise(ArgumentError) { rlink << [33] }
    assert_raise(ArgumentError) { rlink << [33,100,1] }

  end
  def test_init_RouterLinkP2P
    _link = {:metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    assert_equal("type: p2p  id: 192.168.8.0  data: 255.255.255.240  metric: 1", RouterLinkP2P.new(_link).to_s)
    assert_equal("c0a80800fffffff001000001", RouterLinkP2P.new(_link).to_shex)
    assert_equal(1, RouterLinkP2P.new(_link).to_hash[:type])
    assert_equal(1, RouterLinkP2P.new(_link).to_hash[:metric])
    assert_equal("255.255.255.240", RouterLinkP2P.new(_link).to_hash[:data])
    assert_equal("192.168.8.0", RouterLinkP2P.new(_link).to_hash[:id])
    link = RouterLinkP2P.new(_link)
    assert_equal(link.enc, RouterLinkP2P.new(link.to_hash).enc)
  end
  def test_init_RouterLinkTransit
    _link = {:metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    assert_equal("type: transit  id: 192.168.8.0  data: 255.255.255.240  metric: 1", RouterLinkTransit.new(_link).to_s)
    assert_equal("c0a80800fffffff002000001", RouterLinkTransit.new(_link).to_shex)
    assert_equal(2, RouterLinkTransit.new(_link).to_hash[:type])
    assert_equal(1, RouterLinkTransit.new(_link).to_hash[:metric])
    assert_equal("255.255.255.240", RouterLinkTransit.new(_link).to_hash[:data])
    assert_equal("192.168.8.0", RouterLinkTransit.new(_link).to_hash[:id])
    link = RouterLinkTransit.new(_link)
    assert_equal(link.enc, RouterLinkTransit.new(link.to_hash).enc)
  end
  def test_init_RouterLinkStub
    _link = {:metric=>1, :data=>"255.255.255.240", :id=>"192.168.8.0"}
    assert_equal("type: stub  id: 192.168.8.0  data: 255.255.255.240  metric: 1", RouterLinkStub.new(_link).to_s)
    assert_equal("c0a80800fffffff003000001", RouterLinkStub.new(_link).to_shex)
    assert_equal(3, RouterLinkStub.new(_link).to_hash[:type])
    assert_equal(1, RouterLinkStub.new(_link).to_hash[:metric])
    assert_equal("255.255.255.240", RouterLinkStub.new(_link).to_hash[:data])
    assert_equal("192.168.8.0", RouterLinkStub.new(_link).to_hash[:id])
    assert_equal("stub", RouterLinkStub.new().type_to_s)
    
    link = RouterLinkStub.new(_link)
    assert_equal(link.enc, RouterLinkStub.new(link.to_hash).enc)
  end
  def test_RouterLink_type_to_s
    assert_equal("p2p", RouterLink.type_to_s[1])
    assert_equal("transit", RouterLink.type_to_s[2])
    assert_equal("stub", RouterLink.type_to_s[3])
    assert_equal("vl", RouterLink.type_to_s[4])
  end
  def test_RouterLink_type_to_i
    assert_equal(3, RouterLink.type_to_i["stub"])
    assert_equal(1, RouterLink.type_to_i["p2p"])
    assert_equal(2, RouterLink.type_to_i["transit"])
    assert_equal(nil, RouterLink.type_to_i["bogus"])
  end
  def test_key
    assert_equal([1,'1.1.1.1'],@rlink1.key)
    assert_equal([1,'1.1.1.3'],@rlink3.key)
  end
  def test_init_RouterLinkVL
  end
end

class RouterLSA_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  
  def setup
    @rlsa = RouterLSA.new()
    @rlsa << @rlink1 = RouterLink.p2p({:id=>'1.1.1.1', :data=>'255.255.255.255', :metric=>11,})
    @rlsa << @rlink2 = RouterLink.p2p({:id=>'1.1.1.2', :data=>'255.255.255.255', :metric=>12,})
    @rlsa << @rlink22 = RouterLink.p2p({:id=>'1.1.1.2', :data=>'255.255.255.255', :metric=>122,})
    @rlsa << @rlink3 = RouterLink.p2p({:id=>'1.1.1.3', :data=>'255.255.255.255', :metric=>13,})
    @rlsa << @rlink4 = RouterLink.p2p({:id=>'1.1.1.4', :data=>'255.255.255.255', :metric=>14,})
    @rlsa << @rlink5 = RouterLink.p2p({:id=>'1.1.1.5', :data=>'255.255.255.255', :metric=>15,})
  end
  def test_init_RouterLink
    rlsa = "
    00 01 22 01 0a ff 08 06 0a ff 08 06 80 00 01 6b
    e3 f5 00 60 00 00 00 06 c0 a8 08 00 ff ff ff f0
    03 00 00 01 01 01 01 01 0a fe f1 f1 01 00 00 01
    0a fe f1 00 ff ff ff 00 03 00 00 01 c0 a8 fe f1
    ff ff ff ff 03 00 00 00 0a ff 08 06 ff ff ff ff
    03 00 00 00 c0 a8 08 3c ff ff ff fc 03 00 00 01
    "
    lsa = Ospf::RouterLSA.new([rlsa.split.join].pack('H*'))
    assert_equal(rlsa.split.join, lsa.to_shex)
    
    assert_equal(6, lsa.links.size)
    assert_equal(Array, lsa.links.class)
    assert_equal("10.255.8.6", lsa.to_hash[:lsid])
    assert_equal("10.255.8.6", lsa.to_hash[:advr])
    assert_equal(0x22, lsa.to_hash[:options])
    assert_equal(0x8000016b, lsa.to_hash[:seqn])
    assert_equal(0xe3f5, lsa.to_hash[:csum])
    link = lsa.lookup(3,'10.254.241.0')
    assert_match(/type: stub  id: 10.254.241.0/,link.to_s)
  end
  def test_init_RouterLink_mt_id
    rlsa = "
    00 01 22 01 0a ff 08 02 0a ff 08 02 80 00 00 03
    99 c4 00 40 00 00 00 02 02 02 02 02 0a fe e9 e9
    01 02 00 01 21 00 00 14 22 00 00 ff 0a fe e9 00
    ff ff ff 00 03 02 00 01 21 00 00 14 22 00 00 ff
    "
    lsa  = Ospf::RouterLSA.new([rlsa.split.join].pack('H*'))
    
    assert_match(/bits 0x0, link count 2\n\s*id 2.2.2.2, data 10.254.233.233, Type Point-to-point \(1\)\n\s*Topology /,lsa.to_s_junos_style(:detailed))
    
    assert_equal(rlsa.split.join, lsa.to_shex)
    assert_equal(2, lsa.links.size)
    assert_equal("10.255.8.2", lsa.to_hash[:lsid])
    assert_equal("10.255.8.2", lsa.to_hash[:advr])
    assert_equal(0x22, lsa.to_hash[:options])
    assert_equal(0x80000003, lsa.to_hash[:seqn])
    assert_equal(0x99c4, lsa.to_hash[:csum])

    assert_equal(33,lsa.to_hash[:links][0][:mt_id][0][:id])
    assert_equal(34,lsa.to_hash[:links][0][:mt_id][1][:id])
    assert_equal(20,lsa.to_hash[:links][0][:mt_id][0][:metric])
    assert_equal(255,lsa.to_hash[:links][0][:mt_id][1][:metric])

  end
  def test_nwveb
    lsa = Ospf::RouterLSA.new()
    lsa.setABR
    assert_equal(1, lsa.to_hash[:nwveb])
    lsa.setVL
    assert_equal(5, lsa.to_hash[:nwveb])
    lsa.setASBR
    assert_equal(7, lsa.to_hash[:nwveb])
    lsa.setWr
    assert_equal(15, lsa.to_hash[:nwveb])
    lsa.setNt
    assert_equal(31, lsa.to_hash[:nwveb])
    lsa.setABR
    lsa.setVL
    lsa.setASBR
    lsa.setNt
    lsa.setWr
    assert_equal(true,lsa.isWr?)
    assert_equal(true,lsa.isNt?)
    assert_equal(true,lsa.isABR?)
    assert_equal(true,lsa.isASBR?)
    assert_equal(true,lsa.isVL?)
    
    assert_equal(31, lsa.to_hash[:nwveb])
    lsa.unsetNt
    assert_equal(15, lsa.to_hash[:nwveb])
    lsa.unsetWr
    assert_equal(7, lsa.to_hash[:nwveb])
    lsa.unsetABR
    assert_equal(6, lsa.to_hash[:nwveb])
    lsa.unsetVL
    assert_equal(2, lsa.to_hash[:nwveb])
    lsa.unsetASBR
    assert_equal(0, lsa.to_hash[:nwveb])
    assert_equal(false,lsa.isABR?)
    assert_equal(false,lsa.isASBR?)
    assert_equal(false,lsa.isVL?)

    lsa.unsetABR
    lsa.unsetVL
    lsa.unsetASBR
    assert_equal(0, lsa.to_hash[:nwveb])
  end

  def test_lookup
    assert_equal(RouterLink,@rlsa.lookup(1,'1.1.1.1')[0].class)
    assert_equal(2,@rlsa.lookup(@rlink2).size)
    assert_equal(12,@rlsa.lookup(@rlink2)[0].metric)
    assert_equal(122,@rlsa.lookup(@rlink2)[1].metric)
    assert_equal('1.1.1.5',@rlsa.lookup(@rlink5.key)[0].to_hash[:id])
    assert_equal('1.1.1.3',@rlsa.lookup(@rlink3.key)[0].to_hash[:id])
    assert_equal('1.1.1.3',@rlsa.lookup(@rlink3)[0].to_hash[:id])
  end
  def test_has?
    assert_equal(true,@rlsa.has?(1,'1.1.1.3'))
    assert_equal(false,@rlsa.has?(1,'9.9.9.9'))
  end
  def test_add
    rlsa = RouterLSA.new()
    rlsa << rlink1 = RouterLink.p2p({:id=>'1.1.1.1', :data=>'255.255.255.255', :metric=>11,})
    assert_equal(false, rlsa.has?(1,'2.2.2.2'))
    assert_equal(1,rlsa.links.compact.size)
    rlsa << {:id=>'2.2.2.2', :data=>'255.255.255.255', :metric=>11, :type=>1}
    assert_equal(2,rlsa.links.compact.size)
    rlsa << {:id=>'2.2.2.2', :data=>'255.255.255.255', :metric=>11, :type=>1}
    assert_equal(3,rlsa.links.compact.size)
  end
  def test_delete
    rlsa = RouterLSA.new()
    rlsa << rlink1 = RouterLink.p2p({:id=>'1.1.1.1', :data=>'255.255.255.255', :metric=>11,})
    rlsa << {:id=>'2.2.2.2', :data=>'255.255.255.255', :metric=>121, :type=>1}
    rlsa << {:id=>'2.2.2.2', :data=>'255.255.255.255', :metric=>122, :type=>1}
    rlsa << {:id=>'3.3.3.3', :data=>'255.255.255.255', :metric=>13, :type=>1}
    rlsa << {:id=>'4.4.4.4', :data=>'255.255.255.255', :metric=>14, :type=>1}
    assert_equal(5,rlsa.links.compact.size)
    rlsa.delete(1,'4.4.4.4')
    assert_equal(4,rlsa.links.compact.size)
    assert_equal(false,rlsa.has?(1,'4.4.4.4'))
    rlsa.delete(1,'2.2.2.2')
    assert_equal(3,rlsa.links.size)
    assert_equal(true,rlsa.has?(1,'2.2.2.2'))
    assert_equal(122, rlsa.lookup(1,'2.2.2.2')[0].metric)
    rlsa.delete(1,'2.2.2.2')
    rlsa.delete(1,'3.3.3.3')
    assert_equal(1,rlsa.links.size)
    rlsa.delete(rlink1)
    assert_equal([], rlsa.links)
  end
end

__END__
