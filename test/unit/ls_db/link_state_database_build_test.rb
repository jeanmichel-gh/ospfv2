require "test/unit"
require "ls_db/link_state_database"
require 'packet/ospf_packet'

class TestLsDbLinkStateBuildDatabase < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::LSDB

def _test_add_link_to_stub
  ls_db = LinkStateDatabase.new(:area_id=> 0)
  ls_db.add_link_to_stub_network :router_id=> 1, :link_id => '99.99.1.0', :link_data => '255.255.255.0'
  assert_equal '99.99.1.0', ls_db[1,1][0].link_id.to_ip
  assert_equal '255.255.255.0', ls_db[1,1][0].link_data.to_ip
  assert_equal 0, ls_db[1,1][0].metric.to_i
  ls_db.add_link_to_stub_network :router_id=> 1, :network => '99.99.1.1/24', :metric=>10
  assert_equal '99.99.1.0', ls_db[1,1][0].link_id.to_ip
  assert_equal '255.255.255.0', ls_db[1,1][0].link_data.to_ip  
  assert_equal 10, ls_db[1,1][0].metric.to_i
end

def test_add_adjacency
  ls_db = LinkStateDatabase.new(:area_id=> 0)
  ls_db.add_adjacency(1, 2, '192.168.0.1/24', 2)
  
  assert_equal 2, ls_db[:router,1].links.size
  ls_db.add_adjacency(1, 3, '192.168.1.1/24', 2)
  assert_equal 4, ls_db[:router,1].links.size
  ls_db.add_adjacency(2, 3, '192.168.2.1/24', 2)
  assert_equal 2, ls_db[:router,2].links.size
  assert_equal 2, ls_db.size
  assert_equal Router, ls_db[:router, 1].class
  assert_equal RouterLink::PointToPoint, ls_db[:router,1][0].class
  
  assert_equal 4, ls_db[:router,1].links.size    
  lsa = ls_db.remove_adjacency(1, 2, '192.168.0.1/24')
  assert_equal 2, ls_db[:router,1].links.size    
  ls_db.remove_adjacency(1, 3, '192.168.1.1/24')
  assert_equal 0, ls_db[:router,1].links.size
  
  assert_equal 2, ls_db[:router,2].links.size
  lsa = ls_db.remove_adjacency(2, 3, '192.168.2.1/24')
  assert_equal 0, ls_db[:router,2].links.size
  
  assert ls_db.advertised_routers.has?('0.0.0.1')
  assert ls_db.advertised_routers.has?('0.0.0.2')
  assert ! ls_db.advertised_routers.has?('0.0.0.3')
  assert ls_db.advertised_routers.has?(1)
  assert ls_db.advertised_routers.has?(2)
  assert ! ls_db.advertised_routers.has?(3)
  assert ls_db.proxied?('0.0.0.1')
  assert ls_db.proxied?(2)
  assert ! ls_db.proxied?('0.0.0.3')
end

def test_add_adjacency_from_hash
  ls_db = LinkStateDatabase.new(:area_id=> 0)
  ls_db.add_adjacency :router_id =>1, :neighbor_router_id => 4, :prefix => '192.168.4.1/24', :metric=>2

  assert_equal '0.0.0.1', ls_db[1,1].ls_id.to_ip
  assert_equal 2, ls_db[1,1][0].metric.to_i    

  assert_equal :point_to_point, ls_db[1,1][0].router_link_type.to_sym
  assert_equal 'LinkId: 0.0.0.4', ls_db[1,1][0].link_id.to_s
  assert_equal 'LinkData: 192.168.4.1', ls_db[1,1][0].link_data.to_s

  assert_equal :stub_network, ls_db[1,1][1].router_link_type.to_sym
  assert_equal 'LinkId: 192.168.4.0', ls_db[1,1][1].link_id.to_s
  assert_equal 'LinkData: 255.255.255.0', ls_db[1,1][1].link_data.to_s
  #puts ls_db.to_s
end

def test_1
  
  # 
  # point-to-point:
  # 
  #                88.0.0.0/24
  #    routerA <---- p2p ------> routerB
  #           .1              .2
  # 
  # jme@olive> show ospf database logical-router routerA detail 
  # 
  #     OSPF link state database, Area 0.0.0.0
  #  Type       ID               Adv Rtr           Seq      Age  Opt  Cksum  Len 
  # Router  *88.0.0.1         88.0.0.1         0x80000003   126  0x22 0xa5bc  48
  #   bits 0x0, link count 2
  #   id 88.0.0.2, data 88.0.0.1, Type PointToPoint (1)
  #     Topology count: 0, Default metric: 1
  #   id 88.0.0.0, data 255.255.255.0, Type Stub (3)
  #     Topology count: 0, Default metric: 1
  # Router   88.0.0.2         88.0.0.2         0x80000002   127  0x22 0x9bc5  48
  #   bits 0x0, link count 2
  #   id 88.0.0.1, data 88.0.0.2, Type PointToPoint (1)
  #     Topology count: 0, Default metric: 1
  #   id 88.0.0.0, data 255.255.255.0, Type Stub (3)
  #     Topology count: 0, Default metric: 1
  # 
  # 
  # routerA:  set router-options router-id 0.0.0.10
  # 
  #     OSPF link state database, Area 0.0.0.0
  #  Type       ID               Adv Rtr           Seq      Age  Opt  Cksum  Len 
  # Router  *10.0.0.0         10.0.0.0         0x80000008  1294  0x22 0x6695  48
  #   bits 0x0, link count 2
  #   id 88.0.0.2, data 88.0.0.1, Type PointToPoint (1)
  #     Topology count: 0, Default metric: 1
  #   id 88.0.0.0, data 255.255.255.0, Type Stub (3)
  #     Topology count: 0, Default metric: 1
  # Router   88.0.0.2         88.0.0.2         0x8000000b  1291  0x22 0x5b4c  48
  #   bits 0x0, link count 2
  #   id 10.0.0.0, data 88.0.0.2, Type PointToPoint (1)
  #     Topology count: 0, Default metric: 1
  #   id 88.0.0.0, data 255.255.255.0, Type Stub (3)
  #     Topology count: 0, Default metric: 1
  # 
  # 
  ls_db = LinkStateDatabase.new(:area_id=> 0)
  ls_db.add_p2p_adjacency :router_id =>'88.0.0.1', :neighbor_router_id => '88.0.0.2', :prefix => '88.0.0.1/24', :metric=>1
  ls_db.add_p2p_adjacency :router_id =>'88.0.0.2', :neighbor_router_id => '88.0.0.1', :prefix => '88.0.0.2/24', :metric=>1

  # if router_id is not specified use address part of prefix
  ls_db = LinkStateDatabase.new(:area_id=> 0)
  ls_db.add_p2p_adjacency :neighbor_router_id => '88.0.0.2', :prefix => '88.0.0.1/24', :metric=>1
  ls_db.add_p2p_adjacency :neighbor_router_id => '88.0.0.1', :prefix => '88.0.0.2/24', :metric=>1

  # routerA with router-id 10
  ls_db = LinkStateDatabase.new(:area_id=> 0)
  ls_db.add_p2p_adjacency :router_id => '10.0.0.0', :neighbor_router_id => '88.0.0.2', :prefix => '88.0.0.1/24', :metric=>1
  ls_db.add_p2p_adjacency :router_id =>'88.0.0.2', :neighbor_router_id => '10.0.0.0', :prefix => '88.0.0.2/24', :metric=>1

  ls_db.add_loopback :router_id=> '10.0.0.0', :address=>'99.99.1.1'
  
  ls_db.add_p2p_adjacency  :neighbor_router_id => '88.0.0.2', :prefix => '192.168.1.200/24', :metric=>1
  
  
    
end


end
