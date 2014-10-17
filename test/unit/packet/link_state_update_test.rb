require "test/unit"

require "packet/link_state_update"

class TestPacketLinkStateUpdate < Test::Unit::TestCase
  include OSPFv2
  def test_1
    s =              "0204 0088 0aff 0801 0000 0000
    0x0020:  3fea 0000 0000 0000 0000 0000 0000 0001
    0x0030:  0033 2201 0aff 0801 0aff 0801 8000 0421
    0x0040:  3d40 006c 0000 0007 0101 0101 0d0d 0d01
    0x0050:  0100 0001 0d0d 0d00 ffff ff00 0300 0001
    0x0060:  0aff 0801 ffff ffff 0300 0000 0aff 0804
    0x0070:  c0a8 0831 0100 0001 c0a8 0830 ffff fffc
    0x0080:  0300 0001 0aff 0802 c0a8 082d 0100 0001
    0x0090:  c0a8 082c ffff fffc 0300 0001
    ".split.find_all { |n| n =~/^[[:xdigit:]]{4}$/ }.join
    assert  LinkStateUpdate.new([s].pack('H*'))
    ls_update = LinkStateUpdate.new([s].pack('H*'))
    assert_equal 1, ls_update.number_of_lsa
    assert_equal OSPFv2::Router, ls_update[0].class
    
  end
  
  def test_2
    ls_db = OSPFv2::LSDB::LinkStateDatabase.new(:area_id=> 0)
    ls_db.add_loopback :router_id=> '2.2.2.2', :address=> '192.168.1.1', :metric=>10
    ls_db.add_loopback :router_id=> '3.3.3.3', :address=> '192.168.1.2', :metric=>20
    lsu = LinkStateUpdate.new :lsas => ls_db.lsas
    assert_equal 2, lsu.lsas.size
    assert_equal "AdvertisingRouter: 2.2.2.2", lsu[0].advertising_router.to_s
  end
  
  def test_ls_ack
   
     s = %{
     0x0000:  0204 0100 0101 0101 0000 0000 4ba5 0000
     0x0001:  0000 0000 0000 0000 0000 0004 0000 2201
     0x0002:  0000 0002 0000 0002 8000 008a efc0 0030
     0x0003:  0200 0002 0000 0003 c0a8 0501 0100 0002
     0x0004:  c0a8 0500 ffff ff00 0300 0002 0000 2201
     0x0005:  0000 0001 0000 0001 8000 008a 8cb0 0054
     0x0006:  0200 0005 0000 0002 c0a8 0001 0100 0002
     0x0007:  c0a8 0000 ffff ff00 0300 0002 0000 0003
     0x0008:  c0a8 0301 0100 0002 0000 0004 c0a8 0301
     0x0009:  0100 0002 c0a8 0300 ffff ff00 0300 0002
     0x000a:  0000 2201 0000 0003 0000 0003 8000 008a
     0x000b:  0c9f 0030 0200 0002 0000 0004 c0a8 0601
     0x000c:  0100 0002 c0a8 0600 ffff ff00 0300 0002
     0x000d:  0000 2201 0000 0005 0000 0005 8000 008a
     0x000e:  0e97 0030 0200 0002 0000 0004 c0a8 0701
     0x000f:  0100 0002 c0a8 0700 ffff ff00 0300 0002
     }.split.find_all { |n| n =~/^[[:xdigit:]]{4}$/ }.join
     
     ls_update = LinkStateUpdate.new([s].pack('H*'))
     # 
     # $style = :junos_verbose     
     # puts ls_update
     
  end
  
end
