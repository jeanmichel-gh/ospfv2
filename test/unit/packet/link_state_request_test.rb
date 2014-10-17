require "test/unit"

require "packet/link_state_request"

class TestPacketLinkStateRequest < Test::Unit::TestCase
  include OSPFv2
  def test_new_from_bits
    assert LinkStateRequest.new
    s = '0203003cc0a801c800000000273700000000000000000000000000010202020202020202000000010303030303030303000000010000000100000001'
    assert_equal s, LinkStateRequest.new([s].pack('H*')).to_shex
    # puts LinkStateRequest.new([s].pack('H*')).to_s
  end
  def test_to_lsu
    ls_db = OSPFv2::LSDB::LinkStateDatabase.new(:area_id=> 0)
    ls_db.add_loopback :router_id=> '2.2.2.2', :address=> '192.168.1.1', :metric=>10
    ls_db.add_loopback :router_id=> '3.3.3.3', :address=> '192.168.1.2', :metric=>20
    ls_db.add_adjacency(1, 2, '192.168.0.1/24', 2)
    s = '0203003cc0a801c800000000273700000000000000000000000000010202020202020202000000010303030303030303000000010000000100000001'
    lsr = LinkStateRequest.new([s].pack('H*'))
    assert_equal 3, lsr.requests.size
    assert_equal Array, lsr.to_lsu(ls_db).class
    lsr.to_lsu(ls_db)
    assert_equal 1, lsr.to_lsu(ls_db).size
    assert_equal 3, lsr.to_lsu(ls_db, :area_id=> '1.2.3.4')[0].lsas.size

  end
  
  def test_new_from_key
    reqlist=[[1,2,3],[4,5,6]]
    lr = LinkStateRequest.new :area_id => 1, :router_id=> 2, :requests=> reqlist
    assert_equal 2, lr.requests.size
  end
  
  
end


__END__

#
#  Created by Jean-Michel Esnault.
#  Copyright (c) 2008. All rights reserved.
#

require 'test/unit'
require 'pp'
require 'dd'
require 'lsr'

class RequestLSA_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    _req1 = {:lstype => 1, :lsid=> "255.254.253.251", :advr=> "255.1.2.255",}
    assert_equal("00000001fffefdfbff0102ff", Ospf::RequestLSA.new(_req1).to_shex)
    assert_equal("lstype: 1, lsid: 255.254.253.251, advr: 255.1.2.255", Ospf::RequestLSA.new(_req1).to_s)
    assert_equal("255.254.253.251", Ospf::RequestLSA.new(_req1).to_hash[:lsid])
    assert_equal("255.1.2.255", Ospf::RequestLSA.new(_req1).to_hash[:advr])
    assert_equal(1, Ospf::RequestLSA.new(_req1).to_hash[:lstype])
    req1 = Ospf::RequestLSA.new(_req1)
    assert_equal(req1.to_shex, Ospf::RequestLSA.new(req1.enc).to_shex)
    assert_equal([1, "255.254.253.251", "255.1.2.255"],req1.key)
  end
end

class LSR_Test < Test::Unit::TestCase # :nodoc:
  include Ospf
  def test_init
    lsr = Ospf::LSR.new({:area=>"0.0.0.0", :rid=>"10.255.8.1"})
    lsr.add(Ospf::RequestLSA.new({:lstype => 1, :lsid=> "255.254.253.251", :advr=> "255.1.1.255",}))
    assert_equal("020300240aff080100000000ebdb0000000000000000000000000001fffefdfbff0101ff", lsr.to_shex)
    lsr.add(Ospf::RequestLSA.new({:lstype => 2, :lsid=> "255.254.253.252", :advr=> "255.1.2.255",}))
    lsr.add(Ospf::RequestLSA.new({:lstype => 3, :lsid=> "255.254.253.253", :advr=> "255.1.3.255",}))
    lsr.add(Ospf::RequestLSA.new({:lstype => 4, :lsid=> "255.254.253.254", :advr=> "255.1.4.255",}))
    assert_equal("version: 2, type: 3, rid: 10.255.8.1, area: 0.0.0.0, \nLink State Request:\n  lstype: 1, lsid: 255.254.253.251, advr: 255.1.1.255\n  lstype: 2, lsid: 255.254.253.252, advr: 255.1.2.255\n  lstype: 3, lsid: 255.254.253.253, advr: 255.1.3.255\n  lstype: 4, lsid: 255.254.253.254, advr: 255.1.4.255", lsr.to_s)      
    lsr.each { |req| assert_equal(3,req.key.size) }
  end
  def test_build

    s = "
    02 03 01 14 0a ff f5 2c 00 00 00 00
    50 1d 00 00 00 00 00 00 00 00 00 00 00 00 00 04
    00 02 00 01 00 02 00 01 00 00 00 05 41 00 03 00
    00 01 00 01 00 00 00 05 41 00 01 00 00 01 00 01
    00 00 00 03 21 00 04 00 00 02 00 02 00 00 00 05
    51 00 04 00 00 02 00 01 00 00 00 05 41 00 04 00
    00 01 00 01 00 00 00 01 00 01 00 02 00 01 00 02
    00 00 00 05 51 00 05 00 00 02 00 01 00 00 00 03
    21 00 01 00 00 02 00 02 00 00 00 03 21 00 05 00
    00 02 00 02 00 00 00 03 21 00 02 00 00 02 00 02
    00 00 00 01 00 02 00 02 00 02 00 02 00 00 00 03
    21 00 03 00 00 02 00 02 00 00 00 04 00 01 00 01
    00 01 00 01 00 00 00 01 00 02 00 01 00 02 00 01
    00 00 00 05 51 00 03 00 00 02 00 01 00 00 00 05
    51 00 02 00 00 02 00 01 00 00 00 05 51 00 01 00
    00 02 00 01 00 00 00 05 41 00 02 00 00 01 00 01
    00 00 00 05 41 00 05 00 00 01 00 01 00 00 00 01
    00 01 00 01 00 01 00 01                        
    ".split.join

    lsr = Ospf::LSR.new([s].pack('H*'))
    assert_equal(s, lsr.to_shex)


    sdd = "
    02 02 01 c4 00 01 00 01 00 00 00 00
    91 d9 00 00 00 00 00 00 00 00 00 00 05 dc 00 00
    0a fc a4 1e 00 08 00 04 00 02 00 01 00 02 00 01
    80 00 00 01 00 00 00 00 00 08 00 05 41 00 03 00
    00 01 00 01 80 00 00 01 00 00 00 00 00 08 00 05
    41 00 01 00 00 01 00 01 80 00 00 01 00 00 00 00
    00 08 00 03 21 00 04 00 00 02 00 02 80 00 00 01
    00 00 00 00 00 08 00 05 51 00 04 00 00 02 00 01
    80 00 00 01 00 00 00 00 00 08 00 05 41 00 04 00
    00 01 00 01 80 00 00 01 00 00 00 00 00 08 22 01
    00 01 00 02 00 01 00 02 80 00 00 01 00 00 00 00
    00 08 00 05 51 00 05 00 00 02 00 01 80 00 00 01
    00 00 00 00 00 08 00 03 21 00 01 00 00 02 00 02
    80 00 00 01 00 00 00 00 00 08 00 03 21 00 05 00
    00 02 00 02 80 00 00 01 00 00 00 00 00 08 00 03
    21 00 02 00 00 02 00 02 80 00 00 01 00 00 00 00
    00 08 22 01 00 02 00 02 00 02 00 02 80 00 00 01
    00 00 00 00 00 08 00 03 21 00 03 00 00 02 00 02
    80 00 00 01 00 00 00 00 00 08 00 04 00 01 00 01
    00 01 00 01 80 00 00 01 00 00 00 00 00 08 22 01
    00 02 00 01 00 02 00 01 80 00 00 01 00 00 00 00
    00 08 00 05 51 00 03 00 00 02 00 01 80 00 00 01
    00 00 00 00 00 08 00 05 51 00 02 00 00 02 00 01
    80 00 00 01 00 00 00 00 00 08 00 05 51 00 01 00
    00 02 00 01 80 00 00 01 00 00 00 00 00 08 00 05
    41 00 02 00 00 01 00 01 80 00 00 01 00 00 00 00
    00 08 00 05 41 00 05 00 00 01 00 01 80 00 00 01
    00 00 00 00 00 08 22 01 00 01 00 01 00 01 00 01
    80 00 00 01 00 00 00 00                        

    ".split.join

    dd = DD.new([sdd].pack('H*'))

    lsr_list = {}
    dd.each { |lsa|
      lsr_list.store(lsa.key,lsa)
    }

    lsr = Ospf::LSR.build('0.0.0.0', '1.1.1.1', lsr_list.collect{ |k,lsa_h| lsa_h})[0]
    assert_equal("0203011401010101000000004e4700000000000000000000000000032100040000020002000000054100010000010001000000054100030000010001000000040002000100020001000000010001000200010002000000054100040000010001000000055100040000020001000000055100050000020001000000032100010000020002000000010002000200020002000000032100020000020002000000032100050000020002000000032100030000020002000000010002000100020001000000040001000100010001000000054100020000010001000000055100010000020001000000055100020000020001000000055100030000020001000000010001000100010001000000054100050000010001", lsr.to_shex)
    assert_equal(lsr.enc, LSR.new(lsr.enc).enc)

    lsdb = LinkStateDatabase.create(50,5)
    assert_equal(4, LSR.build('1.1.1.1', '0.0.0.0', lsdb.lsas_headers).size)
  end
  
end


OSPF link state database, Area 0.0.0.0
Age  Options  Type    Link-State ID   Advr Router     Sequence   Checksum  Length
      0x22  router    0.0.0.1         0.0.0.1         0x80000001  0x58f0   48     
      0x22  router    2.2.2.2         2.2.2.2         0x80000001  0xa803   36     
      0x22  router    3.3.3.3         3.3.3.3         0x80000001  0x1b7d   36
      

@ls_db={[1, 33686018, 33686018]=>
  #<OSPFv2::Router:0x007ff42bb40498 @ls_age=#<OSPFv2::Lsa::LsAge:0x007ff42bb40420 @age=0>,@sequence_number=#<OSPFv2::SequenceNumber:0x007ff42bb403f8 @seqn="\x01\x00\x00\x80">, @options=#<OSPFv2::Options:0x007ff42bb4be88 @options=34>, @ls_id=#<OSPFv2::Lsa::LsId:0x007ff42bb4bca8 @id=33686018>, @ls_type=#<OSPFv2::LsType:0x007ff42bb4b3e8 @ls_type=1>, @advertising_router=#<OSPFv2::Lsa::AdvertisingRouter:0x007ff42bb4b690 @id=33686018>, @_length=0, @_rxmt_=false, @links=[#<OSPFv2::RouterLink::StubNetwork:0x007ff42bb49c28 @metric=#<OSPFv2::Metric:0x007ff42bb49840 @metric=10>, @router_link_type=#<OSPFv2::RouterLinkType:0x007ff42bb495c0 @router_link_type=3>, @link_data=#<OSPFv2::RouterLink::LinkData:0x007ff42bb493e0 @id=4294967295>, @link_id=#<OSPFv2::RouterLink::LinkId:0x007ff42bb48fa8 @id=3232235777>, @mt_metrics=[]>], @nwveb=2, @_size="\x00$", @_csum="\xA8\x03">, 
  
  [1, 50529027, 50529027]=>#<OSPFv2::Router:0x007ff42bb486e8 @ls_age=#<OSPFv2::Lsa::LsAge:0x007ff42bb48670 @age=0>, @sequence_number=#<OSPFv2::SequenceNumber:0x007ff42bb48648 @seqn="\x01\x00\x00\x80">, @options=#<OSPFv2::Options:0x007ff42bb48120 @options=34>, @ls_id=#<OSPFv2::Lsa::LsId:0x007ff42bb53ef8 @id=50529027>, @ls_type=#<OSPFv2::LsType:0x007ff42bb53638 @ls_type=1>, @advertising_router=#<OSPFv2::Lsa::AdvertisingRouter:0x007ff42bb538e0 @id=50529027>, @_length=0, @_rxmt_=false, @links=[#<OSPFv2::RouterLink::StubNetwork:0x007ff42bb52da0 @metric=#<OSPFv2::Metric:0x007ff42bb529b8 @metric=20>, @router_link_type=#<OSPFv2::RouterLinkType:0x007ff42bb52738 @router_link_type=3>, @link_data=#<OSPFv2::RouterLink::LinkData:0x007ff42bb52558 @id=4294967295>, @link_id=#<OSPFv2::RouterLink::LinkId:0x007ff42bb52120 @id=3232235778>, @mt_metrics=[]>], @nwveb=2, @_size="\x00$", @_csum="\e}">, 
  
  
  [1, 1, 1]=>#<OSPFv2::Router:0x007ff42bb51680 @ls_age=#<OSPFv2::Lsa::LsAge:0x007ff42bb51608 @age=0>, @sequence_number=#<OSPFv2::SequenceNumber:0x007ff42bb515e0 @seqn="\x01\x00\x00\x80">, @options=#<OSPFv2::Options:0x007ff42bb510b8 @options=34>, @ls_id=#<OSPFv2::Lsa::LsId:0x007ff42bb50ed8 @id=1>, @ls_type=#<OSPFv2::LsType:0x007ff42bb50ac8 @ls_type=1>, @advertising_router=#<OSPFv2::Lsa::AdvertisingRouter:0x007ff42bb50b18 @id=1>, @_length=0, @_rxmt_=false, @links=[#<OSPFv2::RouterLink::PointToPoint:0x007ff42bb509d8 @metric=#<OSPFv2::Metric:0x007ff42bb505f0 @metric=2>, @router_link_type=#<OSPFv2::RouterLinkType:0x007ff42bb50370 @router_link_type=1>, @link_data=#<OSPFv2::RouterLink::LinkData:0x007ff42bb50190 @id=3232235521>, @link_id=#<OSPFv2::RouterLink::LinkId:0x007ff42bb5bce8 @id=2>, @mt_metrics=[]>, #<OSPFv2::RouterLink::StubNetwork:0x007ff42bb5bc98 @metric=#<OSPFv2::Metric:0x007ff42bb5b8b0 @metric=2>, @router_link_type=#<OSPFv2::RouterLinkType:0x007ff42bb5b630 @router_link_type=3>, @link_data=#<OSPFv2::RouterLink::LinkData:0x007ff42bb5b450 @id=4294967040>, @link_id=#<OSPFv2::RouterLink::LinkId:0x007ff42bb5afa0 @id=3232235520>, @mt_metrics=[]>], @nwveb=0, @_size="\x000", @_csum="X\xF0">}, @area_id=#<OSPFv2::LSDB::LinkStateDatabase::AreaId:0x007ff42bb40b78 @id=0>, @advertised_routers=#<OSPFv2::LSDB::AdvertisedRouters:0x007ff42bb40f88 @set=#<Set: {33686018, 50529027, 1}>>, @ls_refresh_interval=180, @offset=0>
