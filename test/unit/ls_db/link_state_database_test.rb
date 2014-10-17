require "test/unit"
require "ls_db/link_state_database"
require 'packet/ospf_packet'

class TestLsDbLinkStateDatabase < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::LSDB
  
  def setup
    @ls_db = []
    @ls_db <<  {
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
          :mt_metrics=>[ {:id=>1, :metric=>11}, {:id=>2, :metric=>22} ]
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
    @ls_db <<   {
        :ls_id=>"192.168.0.1", 
        :ls_age=>0, 
        :ls_type=>:network, 
        :advertising_router=>"1.1.1.1",
        :sequence_number=>2147483649, 
        :options=>0,
        :network_mask=>"255.255.255.0", 
        :attached_routers=>["1.1.1.1", "2.2.2.2",   "3.3.3.3"],
      }
    @ls_db <<    {
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
    @ls_db <<    {
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
    @ls_db <<   {
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
      }
  end

  def test_init
    ls_db =  LinkStateDatabase.new(:ls_db => @ls_db)
    assert_match /Area 0.0.0.0/, ls_db.to_s_junos
    assert_match /Router\s+0.0.4.5\s+1.2.0.0\s+0x80000002\s+10  0x21 0x8a41  56/, ls_db.to_s_junos
    assert_match /ASBRSum  10.0.0.0\s+1.1.1.1\s+0x80000001\s+0  0x00 0x7a75  36/, ls_db.to_s_junos
    assert_match /Network  192.168.0.1\s+1.1.1.1\s+0x80000001\s+0  0x00 0x1bb6  36/, ls_db.to_s_junos
    assert_match /Summary  10.0.0.0\s+1.1.1.1\s+0x80000001\s+0  0x00 0x8868  36/, ls_db.to_s_junos
    assert_match /Extern   10.0.0.0\s+1.1.1.1\s+0x80000001\s+13  0x00 0xb40b  36/, ls_db.to_s_junos
  end

  def __test_add_loopback_1
    ls_db = LinkStateDatabase.new
    ls_db.add_loopback '2.2.2.2', 10
    ls_db.add_loopback '3.3.3.3', 20
    assert_equal 2, ls_db.size
    assert_equal OSPFv2::Router, ls_db[1,'2.2.2.2'].class
    assert_equal 10, ls_db[1,'2.2.2.2'][0].metric.to_i
    assert_equal 10, ls_db[1,'2.2.2.2', '2.2.2.2'][0].metric.to_i
    assert_equal 20, ls_db[1,'3.3.3.3'][0].metric.to_i
  end

  def test_add_loopback
    ls_db = LinkStateDatabase.new(:area_id=> 0)
    ls_db.add_loopback :router_id=>2, :metric=>10, :address=>'192.168.0.1'
    ls_db.add_loopback :router_id=>3, :metric=>20, :address=>'192.168.0.2'
    assert_equal 2, ls_db.size
    assert_equal OSPFv2::Router, ls_db[1,'0.0.0.2'].class
    assert_equal 10, ls_db[1,'0.0.0.2'][0].metric.to_i
    assert_equal 10, ls_db[1,'0.0.0.2', '0.0.0.2'][0].metric.to_i
    assert_equal 20, ls_db[1,3][0].metric.to_i
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
    
    
    # puts ls_db.to_s_ios(false)
    # puts ls_db.to_s_ios(true)
    # puts ls_db.to_s(true)
    
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
  
  
  def test_all_not_ack
    ls_db = LinkStateDatabase.new :area_id=> 1, :ls_db => @ls_db
    assert_equal 5, ls_db.all.size
    assert_equal 0, ls_db.all.find_all { |l| ! l.ack? }.size
    ls_db.each { |l| l.retransmit }
    ls_db[1,'0.0.4.5','1.2.0.0'].ack
    assert_equal 4, ls_db.all.find_all { |l| ! l.ack? }.size
    ls_db[:network,"192.168.0.1","1.1.1.1"].ack
    assert_equal 3, ls_db.all.find_all { |l| ! l.ack? }.size    
  end

  def test_all_xxx
    ls_db = LinkStateDatabase.new :area_id=> 1, :ls_db => @ls_db
    assert_equal 1, ls_db.all_router.size
    assert_equal 1, ls_db.all_network.size
    assert_equal 1, ls_db.all_summary.size
    assert_equal 1, ls_db.all_asbr_summary.size
    assert_equal 1, ls_db.all_as_external.size
    assert @ls_db.to_s
  end
  
  def test_ls_refresh_time
    ls_db = LinkStateDatabase.new :area_id=> 1, :ls_db => @ls_db
    ls_db.add_adjacency :router_id =>1, :neighbor_router_id => 4, :prefix => '192.168.4.1/24', :metric=>2
    assert_equal 1800, ls_db.ls_refresh_time
    assert  ! ls_db.ls_refresh?(ls_db[1,1])
    ls_db[1,1].ls_age=20
    ls_db.ls_refresh_time=10
    assert_equal 10, ls_db.ls_refresh_time
    assert ls_db.ls_refresh?(ls_db[1,1])
  end
  
  def test_refresh
    ls_db = LinkStateDatabase.new(:area_id=> 0)
    ls_db.add_loopback :router_id=>'2.2.2.2', :metric=>10   ,:address=>'192.168.1.1'
    ls_db.add_loopback :router_id=>'3.3.3.3', :metric=>20   ,:address=>'192.168.1.2'
    ls_db.add_adjacency(1, 2, '192.168.2.1/24', 2)
    ls_db.add_adjacency(1, 3, '192.168.3.1/24', 2)
    ls_db.add_adjacency(1, 4, '192.168.4.1/24', 2)
    ls_db.add_adjacency(2, 3, '192.168.5.1/24', 2)
    ls_db.add_adjacency(3, 4, '192.168.6.1/24', 2)
    ls_db.add_adjacency(5, 4, '192.168.7.1/24', 2)
    ls_db.each  { |lsa| lsa.ls_age=1801 }
    ls_db.refresh
    ls_db.each  { |lsa| 
      assert_equal 0x80000002, lsa.sequence_number.to_I
      assert_equal 0, lsa.ls_age.to_i
      assert ! lsa.acked?
    }
  end
  
  def test_to_hash
    ls_db = LinkStateDatabase.new(:area_id=> 0)
    ls_db.add_adjacency(1, 2, '192.168.2.1/24', 2)
    ls_db.add_adjacency(1, 3, '192.168.3.1/24', 2)
    ls_db.add_adjacency(2, 4, '192.168.4.1/24', 2)
    assert_equal [1,2], ls_db.advertised_routers.ids
    assert_equal [1,2], ls_db.to_hash[:advertised_routers]
  end
  
  def test_all_proxied
    ls_db = LinkStateDatabase.new(:area_id=> 0)
    ls_db.add_loopback :router_id=>'2.2.2.2', :metric=>10, :address => '192.168.1.1'
    ls_db.add_loopback :router_id=>'3.3.3.3', :metric=>20, :address => '192.168.1.2'
    ls_db.add_adjacency(1, 2, '192.168.2.1/24', 2)
    ls_db.add_adjacency(1, 3, '192.168.3.1/24', 2)
    ls_db.add_adjacency(2, 4, '192.168.4.1/24', 2)
    assert_equal 4, ls_db.all_proxied.size
    ls_db.advertised_routers - 1
    assert_equal 3, ls_db.all_proxied.size
  end
  
  def test_recv_link_state_update
    ls_db = LinkStateDatabase.new(:area_id=> 0)
    ls_db.add_loopback :router_id=>'2.2.2.2', :metric=>10, :address=> '192.168.1.1'
    ls_db.add_loopback :router_id=>'3.3.3.3', :metric=>20, :address=> '192.168.1.2'
    ls_db.add_adjacency(1, 2, '192.168.2.1/24', 2)
    ls_db.add_adjacency(1, 3, '192.168.3.1/24', 2)
    ls_db.add_adjacency(1, 4, '192.168.4.1/24', 2)
    ls_db.add_adjacency(2, 3, '192.168.5.1/24', 2)
    ls_db.add_adjacency(3, 4, '192.168.6.1/24', 2)
    ls_db.add_adjacency(5, 4, '192.168.7.1/24', 2)
    ls_db.recv_link_state_update _recv_lsu
    # puts ls_db
    # ls_db.all.each { |l| puts l.to_s_junos  }
  end

  private
  
  def _sent_lsu
    s = %{
0204 0154 0101 0101 0000 0000 0a90 0000
0000 0000 0000 0000 0000 0006 0000 2201
0202 0202 0202 0202 8000 0001 4fbf 0024
0200 0001 0202 0202 ffff ffff 0300 000a
0000 2201 0303 0303 0303 0303 8000 0001
d91f 0024 0200 0001 0303 0303 ffff ffff
0300 0014 0000 2201 0000 0002 0000 0002
8000 0001 0337 0030 0200 0002 0000 0003
c0a8 0501 0100 0002 c0a8 0500 ffff ff00
0300 0002 0000 2201 0000 0001 0000 0001
8000 0001 360c 0060 0200 0006 0000 0002
c0a8 0201 0100 0002 c0a8 0200 ffff ff00
0300 0002 0000 0003 c0a8 0301 0100 0002
c0a8 0300 ffff ff00 0300 0002 0000 0004
c0a8 0401 0100 0002 c0a8 0400 ffff ff00
0300 0002 0000 2201 0000 0003 0000 0003
8000 0001 1f16 0030 0200 0002 0000 0004
c0a8 0601 0100 0002 c0a8 0600 ffff ff00
0300 0002 0000 2201 0000 0005 0000 0005
8000 0001 210e 0030 0200 0002 0000 0004
c0a8 0701 0100 0002 c0a8 0700 ffff ff00
0300 0002
    }.split.join
    OspfPacket.factory([s].pack('H*'))
  
  end
  
  def _recv_lsu
    s = %{
0204 0154 c0a8 01c8 0000 0000 0482 0000
0000 0000 0000 0000 0000 0006 0c6f 2201
0202 0202 0202 0202 8000 006c 782b 0024
0200 0001 0202 0202 ffff ffff 0300 000a
0c6f 2201 0303 0303 0303 0303 8000 006c
038a 0024 0200 0001 0303 0303 ffff ffff
0300 0014 0c6f 2201 0000 0002 0000 0002
8000 006c 2ca2 0030 0200 0002 0000 0003
c0a8 0501 0100 0002 c0a8 0500 ffff ff00
0300 0002 0c6f 2201 0000 0001 0000 0001
8000 006c 5f77 0060 0200 0006 0000 0002
c0a8 0201 0100 0002 c0a8 0200 ffff ff00
0300 0002 0000 0003 c0a8 0301 0100 0002
c0a8 0300 ffff ff00 0300 0002 0000 0004
c0a8 0401 0100 0002 c0a8 0400 ffff ff00
0300 0002 0c6f 2201 0000 0003 0000 0003
8000 006c 4881 0030 0200 0002 0000 0004
c0a8 0601 0100 0002 c0a8 0600 ffff ff00
0300 0002 0c6f 2201 0000 0005 0000 0005
8000 006c 4a79 0030 0200 0002 0000 0004
c0a8 0701 0100 0002 c0a8 0700 ffff ff00
0300 0002      
    }.split.join
    OspfPacket.factory([s].pack('H*'))
  end
  
end

__END__



            OSPF Router with ID (1.1.1.1) (Process ID 1)

                Router Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum Link count

                Net Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum

                Summary Net Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum

                Summary ASB Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum

                Type-5 AS External Link States

Link ID         ADV Router      Age         Seq#       Checksum Tag


R1#show ip ospf database 

            OSPF Router with ID (1.1.1.1) (Process ID 1)

                Router Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum Link count
0.0.0.1         0.0.0.1         10          0x80000003 0x00E88F 4
0.1.0.1         0.1.0.1         10          0x80000003 0x00708C 8
0.1.0.2         0.1.0.2         10          0x80000003 0x0082B1 9
0.1.0.3         0.1.0.3         10          0x80000003 0x00FEFC 9
0.1.0.4         0.1.0.4         10          0x80000003 0x00249F 9
0.1.0.5         0.1.0.5         10          0x80000003 0x0004FD 6
0.2.0.1         0.2.0.1         10          0x80000003 0x000142 6
0.2.0.2         0.2.0.2         10          0x80000003 0x00454C 9
0.2.0.3         0.2.0.3         10          0x80000003 0x0077C9 9
0.2.0.4         0.2.0.4         10          0x80000003 0x00767A 9
0.2.0.5         0.2.0.5         10          0x80000003 0x000988 6
1.1.1.1         1.1.1.1         15          0x8000000F 0x00FAB6 5
2.2.2.2         2.2.2.2         1130        0x80000007 0x00BF8F 2

                Net Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum
192.168.0.2     2.2.2.2         1130        0x80000006 0x000AAB

                Summary Net Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum
30.0.1.0        0.1.0.1         11          0x80000003 0x00E457
30.0.2.0        0.1.0.1         11          0x80000003 0x00D961
30.0.3.0        0.2.0.1         11          0x80000003 0x00C672
30.0.4.0        0.2.0.1         11          0x80000003 0x00BB7C

                Summary ASB Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum
0.1.0.1         0.1.0.1         11          0x80000003 0x005305

                Type-5 AS External Link States

Link ID         ADV Router      Age         Seq#       Checksum Tag
50.0.1.0        0.1.0.1         11          0x80000003 0x009158 0
50.0.2.0        0.1.0.1         11          0x80000003 0x008662 0
50.0.3.0        0.1.0.1         11          0x80000003 0x007B6C 0
50.0.4.0        0.1.0.1         11          0x80000003 0x007076 0
50.0.5.0        0.1.0.1         11          0x80000003 0x006580 0
R1# 


   OSPF link state database, Area 0.0.0.0
 Type       ID               Adv Rtr           Seq      Age  Opt  Cksum  Len 
Router   0.0.0.1          0.0.0.1          0x80000001  1419  0x22 0x1dbd  72
Router   0.1.0.1          0.1.0.1          0x80000001  1419  0x22 0x7954  84
Router   0.2.0.1          0.2.0.1          0x80000001  1419  0x22 0x9c61  60
Router   1.1.1.1          1.1.1.1          0x80000023  1371  0x22 0x3870  84
Router   2.2.2.2          2.2.2.2          0x8000000b   819  0x22 0xb793  48
Network  192.168.0.2      2.2.2.2          0x8000000a   819  0x22 0x02af  32
Summary  30.0.1.0         0.1.0.1          0x80000001  1419  0x00 0xe855  28
Summary  30.0.2.0         0.2.0.1          0x80000001  1419  0x00 0xd566  28
ASBRSum  0.1.0.1          0.1.0.1          0x80000001  1419  0x00 0x5703  28
Extern   50.0.1.0         0.1.0.1          0x80000001  1419  0x00 0x9556  48
Extern   50.0.2.0         0.1.0.1          0x80000001  1419  0x00 0x8a60  48

>> 

TODO: ls_db.to_s_ios

R1#show ip ospf database

            OSPF Router with ID (1.1.1.1) (Process ID 1)

                Router Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum Link count
0.0.0.1         0.0.0.1         1238        0x80000001 0x001DBD 4
0.1.0.1         0.1.0.1         1238        0x80000001 0x007954 5
0.2.0.1         0.2.0.1         1238        0x80000001 0x009C61 3
1.1.1.1         1.1.1.1         1237        0x80000023 0x003870 5
2.2.2.2         2.2.2.2         686         0x8000000B 0x00B793 2

                Net Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum
192.168.0.2     2.2.2.2         686         0x8000000A 0x0002AF

                Summary Net Link States (Area 0)

Link ID         ADV Router      Age         Seq#       Checksum
30.0.1.0        0.1.0.1         1238        0x80000001 0x00E855
30.0.2.0        0.2.0.1         1238        0x80000001 0x00D566

          
R1#
R1#

