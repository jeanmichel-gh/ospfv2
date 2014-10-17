require "test/unit"
require "lsa/lsa_factory"

class TestLsaLsa < Test::Unit::TestCase
  def test_asbr_summary
    s = ['000000040101010101010101800000012f27001c0000000000000000'].pack('H*')
    lsa = OSPFv2::Lsa.factory(s)
    assert_equal OSPFv2::AsbrSummary, lsa.class
  end
  def test_summary
    s = ['000000030a000000010101018000000188680024ffffff000000000121000014220000ff'].pack('H*')
    lsa = OSPFv2::Lsa.factory(s)
    assert_equal OSPFv2::Summary, lsa.class
  end
  def test_router
    s = ['000022010047000b0047000b8000000155d70084000000090047000bffffffff030000010046000b0d0044b6010000010d0044b4fffffffc030000010047000a0d0044ba010000010d0044b8fffffffc030000010047000c0d0044c1010000010d0044c0fffffffc030000010048000b0d0045b1010000010d0045b0fffffffc03000001'].pack('H*')
    lsa = OSPFv2::Lsa.factory(s)
    assert_equal OSPFv2::Router, lsa.class
    assert_equal s, lsa.encode
  end

  def test_external
    #TODO unit-test lsa factory external lsa
  end
  
  def test_network
    #TODO unit-test lsa factory network lsa
  end
  
  def test_traffic_engineering_header_only
    s = ['0000000a010000ff0202020280000001cd890014'].pack('H*')
    lsa = OSPFv2::Lsa.factory(s)
    assert_equal(OSPFv2::TrafficEngineering, lsa.class)
    assert_equal(s, lsa.encode)
  end
  
  def test_traffic_engineering_link_tlv
    s = '0000000a010000000000000080000001b2ac0074
    0002 005c 
    0001 0001 01 000000 
    0002 0004 01020304 
    0003 0004 01010101 
    0004 0004 02020202 
    0005 0004 000000ff 
    0006 0004 449c4000 
    0007 0004 445ac000 
    0008 0020 4148000041480000414800004148000041480000414800004148000041480000'.split.join
    lsa = OSPFv2::Lsa.factory([s].pack('H*'))
    assert_equal(OSPFv2::TrafficEngineering, lsa.class)
    assert_equal(s, lsa.to_shex)
  end
  
  #  	  LSA #3
  #  	  Advertising Router 10.255.245.46, seq 0x8000001e, age 8s, length 104
  #  	    Area Local Opaque LSA (10), Opaque-Type Traffic Engineering LSA (1), Opaque-ID 5
  #  	    Options: [External, Demand Circuit]
  #  	    Link TLV (2), length: 100
  #  	      Link Type subTLV (1), length: 1, Point-to-point (1)
  #  	      Link ID subTLV (2), length: 4, 12.1.1.1 (0x0c010101)
  #  	      Local Interface IP address subTLV (3), length: 4, 192.168.208.88
  #  	      Remote Interface IP address subTLV (4), length: 4, 192.168.208.89
  #  	      Traffic Engineering Metric subTLV (5), length: 4, Metric 1
  #  	      Maximum Bandwidth subTLV (6), length: 4, 155.520 Mbps
  #  	      Maximum Reservable Bandwidth subTLV (7), length: 4, 155.520 Mbps
  #  	      Unreserved Bandwidth subTLV (8), length: 32
  #  		TE-Class 0: 155.520 Mbps
  #  		TE-Class 1: 155.520 Mbps
  #  		TE-Class 2: 155.520 Mbps
  #  		TE-Class 3: 155.520 Mbps
  #  		TE-Class 4: 155.520 Mbps
  #  		TE-Class 5: 155.520 Mbps
  #  		TE-Class 6: 155.520 Mbps
  #  		TE-Class 7: 155.520 Mbps
  #  	      Administrative Group subTLV (9), length: 4, 0x00000000
  #  			 0200 0000 45c0 01b0 d0ff 0000 0159 7520
  #  			 c0a8 d067 e000 0005 0204 019c 0aff f531
  #  			 0000 0000 2dde 0000 0000 0000 0000 0000
  #  			 0000 0003 000a 2202 c0a8 a42f 0c01 0101
  #  			 8000 0eba b7e3 0020 ffff fc00 0c01 0101
  #  			 7c01 0001 000a 2201 0c01 0101 0c01 0101
  #  			 8000 3313 0ed3 00e4 0000 0011 c0a8 d043
  #  			 c0a8 d044 0200 0001 c0a8 a42f c0a8 a42f
  #  			 0200 0001 0c01 0101 ffff ffff 0300 0000
  #  			 0aff f52f ffff ffff 0300 0000 7c01 0101
  #  			 7c01 0002 0200 0001 7c01 0201 7c01 0003
  #  			 0200 0001 0a01 0000 ffff 0000 0300 0001
  #  			 0a01 0000 ffff 0000 0300 0001 0a02 0000
  #  			 ffff 0000 0300 0001 0a01 0000 ffff 0000
  #  			 0300 0001 0a02 0000 ffff 0000 0300 0001
  #  			 0aff f52e c0a8 d05b 0100 0001 c0a8 d05a
  #  			 ffff fffe 0300 0001 0aff f52e c0a8 d059
  #  			 0100 0001 c0a8 d058 ffff fffe 0300 0001
  #  			 0aff f52e c0a8 d057 0100 0001 c0a8 d056
  #  			 ffff fffe 0300 0001 0008 220a 0100 0005
  #  			 0aff f52e 8000 001e d240 007c 0002 0064
  #  			 0001 0001 0100 0000 0002 0004 0c01 0101
  #  			 0003 0004 c0a8 d058 0004 0004 c0a8 d059
  #  			 0005 0004 0000 0001 0006 0004 4b94 50c0
  #  			 0007 0004 4b94 50c0 0008 0020 4b94 50c0
  #  			 4b94 50c0 4b94 50c0 4b94 50c0 4b94 50c0
  #  			 4b94 50c0 4b94 50c0 4b94 50c0 0009 0004
  #  			 0000 0000
  require 'packet/ospf_packet'
  require 'lsa/tlv/tlv_factory'
  
  def test_traffic_engineering_link_tlv_2
    s = "
    0204 019c 
    0aff f531
    0000 0000 
    2dde 0000 
    0000 0000 
    0000 0000
    
    0000 0003
    
    000a 22 02 
    c0a8a42f 
    0c010101
    80000eba 
    b7e3 0020 
    fffffc00 
    0c010101
    7c010001 
    
    000a 22 01 
    0c010101 
    0c010101
    80003313 
    0ed3 00e4 
    0000 0011 
    
    c0 a8d043
    c0a8d044 
    0200 0001 c0a8 a42f c0a8 a42f
    0200 0001 0c01 0101 ffff ffff 0300 0000
    0aff f52f ffff ffff 0300 0000 7c01 0101
    7c01 0002 0200 0001 7c01 0201 7c01 0003
    0200 0001 0a01 0000 ffff 0000 0300 0001
    0a01 0000 ffff 0000 0300 0001 0a02 0000
    ffff 0000 0300 0001 0a01 0000 ffff 0000
    0300 0001 0a02 0000 ffff 0000 0300 0001
    0aff f52e c0a8 d05b 0100 0001 c0a8 d05a
    ffff fffe 0300 0001 0aff f52e c0a8 d059
    0100 0001 c0a8 d058 ffff fffe 0300 0001
    0aff f52e c0a8 d057 0100 0001 c0a8 d056
    ffff fffe 0300 0001 0008 220a 0100 0005 
    0aff f52e 8000 001e d240 007c
    
    0002 0064
    0001 0001 0100 0000 
    0002 0004 0c01 0101
    0003 0004 c0a8 d058 
    0004 0004 c0a8 d059
    0005 0004 0000 0001 
    0006 0004 4b94 50c0
    0007 0004 4b94 50c0 
    0008 0020 4b94 50c0 4b94 50c0 4b94 50c0 4b94 50c0 4b94 50c0
    4b94 50c0 4b94 50c0 4b94 50c0 
    0009 0004 0000 0000
    ".split.join
    sbin = [s].pack('H*')
    packet = OSPFv2::OspfPacket.factory([s].pack('H*'))
    assert_equal(OSPFv2::LinkStateUpdate, packet.class)
    assert_equal(3, packet.lsas.size)
    assert_equal([OSPFv2::Network, OSPFv2::Router, OSPFv2::TrafficEngineering], 
      packet.lsas.collect { |lsa| lsa.class })
    # puts packet.lsas[2].to_s_verbose
    assert_equal(s, packet.to_shex)    
  end
  
  def test_router_lsa_from_hash
    
    h_lsa = 
    {
      :sequence_number=>2147483650,
      :advertising_router=>"1.2.0.0",
      :ls_id=>"0.0.4.5",
      :nwveb=>1, 
      :ls_type=>:router,
      :options=> 0x21,
      :ls_age=>10,
      :links=>[
        {
          :link_id=>"1.1.1.1", 
          :link_data=>"255.255.255.255", 
          :router_link_type=>:point_to_point,
          :metric=>11, 
          :mt_metrics=>[]
        }, 
        {
          :link_id=>"1.1.1.2", 
          :link_data=>"255.255.255.255", 
          :router_link_type=>:point_to_point,
          :metric=>12, 
          :mt_metrics=>[]
        }
      ], 
    }
    
    lsa = OSPFv2::Lsa.factory h_lsa
    assert_equal OSPFv2::Router, lsa.class
    assert_equal h_lsa, lsa.to_hash
  end
  
  def test_network_lsa_from_hash
    h_lsa = {
      :ls_id=>"192.168.0.1", 
      :ls_age=>0, 
      :ls_type=>:network, 
      :advertising_router=>"1.1.1.1",
      :sequence_number=>2147483649, 
      :options=>0,
      :network_mask=>"255.255.255.0", 
      :attached_routers=>["1.1.1.1", "2.2.2.2",   "3.3.3.3"],
    }
    lsa = OSPFv2::Lsa.factory h_lsa
    assert_equal OSPFv2::Network, lsa.class
    assert_equal h_lsa, lsa.to_hash
  end
  
  def test_summary_lsa_from_hash
    h_lsa = {
      :sequence_number=>2147483649, 
      :advertising_router=>"1.1.1.1", 
      :ls_id=>"10.0.0.0", 
      :ls_age=>0, 
      :options=>0, 
      :ls_type=>:summary, 
      :netmask=>"255.255.255.0", 
      :metric=>1, 
      :mt_metrics=>[{:id=>33, :metric=>20}, {:id=>34, :metric=>255}]
    }  
    lsa = OSPFv2::Lsa.factory h_lsa
    assert_equal OSPFv2::Summary, lsa.class
    assert_equal h_lsa, lsa.to_hash
  end
  
  def test_asbr_summary_lsa_hash
    h_lsa = {
      :sequence_number=>2147483649, 
      :advertising_router=>"1.1.1.1",
      :ls_id=>"10.0.0.0", 
      :ls_age=>0, 
      :metric=>1, 
      :options=>0, 
      :ls_type=>:asbr_summary, 
      :netmask=>"255.255.255.0", 
      :mt_metrics=>[{:id=>33, :metric=>20}, {:id=>34, :metric=>255}]
    }
    lsa = OSPFv2::Lsa.factory h_lsa
    assert_equal OSPFv2::AsbrSummary, lsa.class
    assert_equal h_lsa, lsa.to_hash
  end
  
  def test_external_lsa_hash
    h_lsa = {
      :sequence_number=>2147483649,
      :ls_age => 13,
      :options=>0, 
      :ls_type => :as_external,
      :advertising_router=>"1.1.1.1",
      :ls_id=>"10.0.0.0",
      :netmask => "255.255.255.0",
      :external_route=> {
        :type=>:e2, 
        :forwarding_address=>"1.2.3.0", 
        :metric=>1, 
        :tag=>255
      },
      :mt_metrics=>[]
    }
    lsa = OSPFv2::Lsa.factory h_lsa
    assert_equal OSPFv2::AsExternal, lsa.class
    assert_equal h_lsa, lsa.to_hash
  end
  
  def test_traffic_engineering_lsa_from_hash
    h_lsa = {:ls_age=>0,
     :ls_type=>:area,
     :advertising_router=>"0.0.0.0",
     :sequence_number=>2147483649,
     :opaque_id=>0,
     :opaque_type=>:te_lsa,
     :top_lvl_tlv=>
      {:tlv_type=>2,
       :tlvs=>
        [{:tlv_type=>1, :link_type=>1},
         {:tlv_type=>2, :link_id=>"1.2.3.4"},
         {:ip_address=>"1.1.1.1", :tlv_type=>3},
         {:ip_address=>"2.2.2.2", :tlv_type=>4},
         {:tlv_type=>5, :te_metric=>255},
         {:max_bw=>10000, :tlv_type=>6},
         {:tlv_type=>7, :max_resv_bw=>7000},
         {:tlv_type=>8,
          :unreserved_bw=>[100, 100, 100, 100, 100, 100, 100, 100]}]},
     :options=>0}
     
    lsa = OSPFv2::Lsa.factory h_lsa
    assert_equal OSPFv2::TrafficEngineering, lsa.class
    assert_equal h_lsa, lsa.to_hash
  end
  
  def test_external_lsa_hash_mt_metrics
    lsa1 = OSPFv2::AsExternal.new_lsdb(:advertising_router=> 1, :mt_metrics=>[{:mt_id=>10, :metric=>20, :tag=>10, :forwarding_address=> '1.1.1.1'}])
    lsa2 = OSPFv2::Lsa.factory lsa1
    assert_equal lsa1.to_shex, lsa2.to_shex
    assert_equal lsa1.to_shex, OSPFv2::Lsa.factory(lsa2.to_hash).to_shex
    assert_equal lsa1.to_hash, lsa2.to_hash
 
   end
  
end

