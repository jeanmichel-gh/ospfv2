require "test/unit"
require 'pp'
require "packet/database_description"

class TestPacketDatabaseDescription < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::LSDB
  def test_new
    s = "020200340404040400000002ea7e0000000000000000000005d8000700000080" +
    "000a00010000001401020304000000c800000000" +
    "000a00010000001401020304000000c800000000" +
    "000a00010000001401020304000000c800000000" +
    "000a00010000001401020304000000c800000000" +
    "000a00010000001401020304000000c800000000" +
    "000a00010000001401020304000000c800000000" +
    "000a00010000001401020304000000c800000000" +
    "000a00010000001401020304000000c800000000" +
    "000a00010000001401020304000000c800000000"  
    dd = DatabaseDescription.new([s].pack('H*'))
    assert_equal dd.to_shex, DatabaseDescription.new(dd).to_shex
    assert DatabaseDescription.new    # dd = DatabaseDescription.new
    dd1 = DatabaseDescription.new
    dd1.imms=7
    dd1.dd_sequence_number= 0xc0aa4f18
    dd1.options=Options.new 0x42
    
    #puts dd.to_s

    s1 = '02020020c0a801c80000000008740000000000000000000005dc0007c0a56c70'
    s2 = '02020020c0a801c80000000025c70000000000000000000005dc0007c0aa4f18'
    
    dd2 = DatabaseDescription.new([s1].pack('H*'))
    assert_equal s1, dd2.to_shex
    dd2 = DatabaseDescription.new([s2].pack('H*'))
    assert_equal s2, dd2.to_shex
    assert_equal 3232386840, dd2.dd_sequence_number
    assert_equal 3232386840, dd2.seqn
    assert_equal 1500, dd2.interface_mtu.to_i
    assert dd2.master?
    assert dd2.init?
    assert dd2.more?
    
    h = {:imms=>7,
     :au_type=>:null,
     :lsas=>[],
     :dd_sequence_number=>3232386840,
     :packet_type=>:dd,
     :area_id=>"0.0.0.0",
     :interface_mtu=>1500,
     :router_id=>"192.168.1.200",
     :options=> 0,
     :ospf_version=>2}
    assert_equal(h, dd2.to_hash)
  end
  def _test_recv
    s = "\002\002\0004\300\250\001\310\000\000\000\000\221\372\000\000\000\000\000\000\000\000\000\000\005\334B\001\300\241\326\356\000\000\"\001\300\250\001\310\300\250\001\310\200\000\000\320\242\r\0000"
    dd = DatabaseDescription.new s
    assert_equal 'database_description', dd.packet_name
  end
  def test_ls_db
      ls_db = LinkStateDatabase.new(:area_id=> 0)
      ls_db.add_loopback :router_id=>'2.2.2.2', :address=>'192.168.1.1', :metric=>10
      ls_db.add_loopback :router_id=>'3.3.3.3', :address=>'192.168.1.2', :metric=>20
      ls_db.add_adjacency(1, 2, '192.168.0.1/24', 2)
      
      assert_equal 3, ls_db.size
      
      dd = OspfPacket.factory( :packet_type=>:dd, :area_id=>"0.0.0.0", :au_type=>:null, :router_id=>"192.168.1.200", :dd_sequence_number=>3232386840, :ospf_version=>2, :interface_mtu=>1500, :lsas=>[], :options=>0, :ls_db => ls_db, :number_of_lsa=>1)
      assert_equal 1, dd.instance_eval { @lsas.size }
      assert_equal 1, ls_db.offset
      assert_equal '00002201020202020202020280000001a8030024', dd.to_shex[-40.. -1]
      assert dd.more?

      dd = OspfPacket.factory( :packet_type=>:dd, :area_id=>"0.0.0.0", :au_type=>:null, :router_id=>"192.168.1.200", :dd_sequence_number=>3232386840, :ospf_version=>2, :interface_mtu=>1500, :lsas=>[], :options=>0, :ls_db => ls_db, :number_of_lsa=>1)
      assert_equal 1, dd.instance_eval { @lsas.size }
      assert_equal 2, ls_db.offset
      assert_equal '000022010303030303030303800000011b7d0024', dd.to_shex[-40.. -1]
      assert dd.more?
      
      dd = OspfPacket.factory( :packet_type=>:dd, :area_id=>"0.0.0.0", :au_type=>:null, :router_id=>"192.168.1.200", :dd_sequence_number=>3232386840, :ospf_version=>2, :interface_mtu=>1500, :lsas=>[], :options=>0, :ls_db => ls_db, :number_of_lsa=>1)
      assert_equal 1, dd.instance_eval { @lsas.size }
      assert_equal 3, ls_db.offset
      assert_equal '0000220100000001000000018000000158f00030', dd.to_shex[-40.. -1]
      assert ! dd.more?
      
      dd = OspfPacket.factory( :packet_type=>:dd, :area_id=>"0.0.0.0", :au_type=>:null, :router_id=>"192.168.1.200", :dd_sequence_number=>3232386840, :ospf_version=>2, :interface_mtu=>1500, :lsas=>[], :options=>0, :ls_db => ls_db, :number_of_lsa=>1)
      assert_equal 0, dd.instance_eval { @lsas.size }
      assert_equal 4, ls_db.offset
      assert ! dd.more?
      assert_equal 24+8, dd.encode.size # no lsa headers
      
      ls_db.offset=0
      dd = OspfPacket.factory( :packet_type=>:dd, :area_id=>"0.0.0.0", :au_type=>:null, :router_id=>"192.168.1.200", :dd_sequence_number=>3232386840, :ospf_version=>2, :interface_mtu=>1500, :lsas=>[], :options=>0, :ls_db => ls_db)
      assert_equal 3, dd.instance_eval { @lsas.size }
      assert (ls_db.offset > 50)
      assert ! dd.more?
      assert_equal 24+8+3*20, dd.encode.size # 3 lsa headers
      
      shex = %{0202005cc0a801c8000000000e8b0000000000000000000005dc0000c0aa4f1800002201020202020202020280000001a8030024000022010303030303030303800000011b7d00240000220100000001000000018000000158f00030
      }.split.join
      assert_equal shex, dd.to_shex
      
  end
  def test_new_from_hash
    h_dd = {:packet_type=>:dd, :area_id=>"0.0.0.0", :imms=>7, :au_type=>:null, :router_id=>"192.168.1.200", :dd_sequence_number=>3232386840, :ospf_version=>2, :interface_mtu=>1500, :options=>0}
    dd = DatabaseDescription.new(h_dd)
    assert_equal DatabaseDescription, dd.class
    assert_equal h_dd.merge(:lsas=>[]), dd.to_hash()
  end
  def test_new_from_hash_with_ls_db
  end


end
