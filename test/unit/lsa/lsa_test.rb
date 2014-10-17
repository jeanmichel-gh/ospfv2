require "test/unit"

require_relative "../../../lib/lsa/lsa"
# require_relative "lsa/lsa"

class TestPacketLsa < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert Lsa.new
    assert_equal '0000000100000000000000008000000195d30014', Lsa.new.to_shex
    hdr = Lsa.new :advertising_router=> '1.1.1.1',
                        :ls_type => :router,
                        :ls_id => '2.2.2.2',
                        :options => 7,
                        :ls_age => 0xffff
    
    assert_equal 'AdvertisingRouter: 1.1.1.1', hdr.advertising_router.to_s
    assert_equal 'LsId: 2.2.2.2', hdr.ls_id.to_s
    assert_equal 'LsType: router', hdr.ls_type.to_s
    assert_equal  7, hdr.options.to_i
    assert_equal  'Options:  0x7  [MC,E,V6]', hdr.options.to_s
    assert_equal  'ffff0701020202020101010180000001b1a40014', hdr.to_shex
    assert_equal hdr.to_shex, Lsa.new_ntop(hdr.encode).to_shex
    assert_equal hdr.to_shex, Lsa.new_ntop(hdr).to_shex
    assert_equal [1, 33686018, 16843009], hdr.key
    hdr.advertising_router='2.2.2.2'
    assert_equal '2.2.2.2',hdr.header_lsa.advertising_router.to_hash
    hdr.ls_id='2.2.2.2'
    assert_equal '2.2.2.2',hdr.header_lsa.advertising_router.to_hash
    # puts hdr
  end
  
  def test_newer
    
    lsa1 = Lsa.new :advertising_router=> '1.1.1.1',
                   :ls_type => :router,
                   :ls_id => '2.2.2.2',
                   :options => 7,
                   :ls_age => 0xffff
    lsa2 = Lsa.new :advertising_router=> '1.1.1.1',
                   :ls_type => :router,
                   :ls_id => '2.2.2.2',
                   :options => 7,
                   :ls_age => 0xffff

   lsa1.instance_eval { @_csum = [0].pack('n') }
   lsa2.instance_eval { @_csum = [0].pack('n') }
                   
    assert (lsa1 <=> lsa2)
    lsa1.ls_age=2
    assert (lsa1 > lsa2)
    lsa2.ls_age=3
    assert (lsa1 == lsa2)
    lsa1.sequence_number + 1
    assert lsa1 > lsa2
    lsa2.sequence_number + 1
    assert (lsa1 == lsa2)
    lsa1.instance_eval { @_csum = [0xabcd].pack('n') }
    assert (lsa1 > lsa2)
    lsa2.instance_eval { @_csum = [0xabcd].pack('n') }
    lsa2.ls_age= 900 + 3
    assert (lsa1 > lsa2)
        
  end
  
  def test_refresh
    advrs = LSDB::AdvertisedRouters.new
    advrs << '1.1.1.1'
    lsa = Lsa.new :advertising_router=> '1.1.1.1',
                   :ls_type => :router,
                   :ls_id => '2.2.2.2',
                   :options => 7,
                   :ls_age => 0xffff
    lsa.ls_age = 13
    assert_equal '0x80000001', lsa.sequence_number.to_s
    assert_equal 13, lsa.ls_age.to_i
    lsa.refresh advrs, 4
    lsa.refresh advrs, 4
    lsa.refresh advrs, 4
    lsa.refresh advrs, 4
    lsa.refresh advrs, 4
    assert_equal '0x80000002', lsa.sequence_number.to_s
    assert_equal 0, lsa.ls_age.to_i
    advrs - '1.1.1.1'
    lsa.ls_age = 13
    lsa.refresh advrs, 4
    assert_equal '0x80000002', lsa.sequence_number.to_s
    assert_equal 13, lsa.ls_age.to_i
    advrs << '1.1.1.1'
    lsa.refresh advrs, 4
    assert_equal '0x80000003', lsa.sequence_number.to_s
    assert_equal 0, lsa.ls_age.to_i
  end
  
  def test_maxage
    lsa = Lsa.new :advertising_router=> '1.1.1.1',
                   :ls_type => :router,
                   :ls_id => '2.2.2.2',
                   :options => 7
    assert ! lsa.maxaged?
    lsa.maxage
    assert lsa.maxaged?
  end
  
  def test_to_s_junos
    lsa = Lsa.new :advertising_router=> '1.1.1.1',
                   :ls_type => :router,
                   :ls_id => '2.2.2.2',
                   :options => 7
    # puts lsa.to_s_junos
  end
  
end

__END__


#TODO: see if these test should be implemented and delete them otherwise.

def test_compare_equal
  header1 = LSA_Header.new(Ospf::LSA_Header.new({:length=>0xffff,
    :lsage => 1,
    :options => 0xee,
    :lstype => 0xdd,
    :lsid => "254.254.254.254",
    :advr => "253.253.253.253",
    :seqn => 0x12345678,
    :csum => 0xdead,
    :length =>0xef 
  }).enc)
  header2 = LSA_Header.new(Ospf::LSA_Header.new(
  {:length=>0xffff,
    :lsage => 1,
    :options => 0xee,
    :lstype => 0xdd,
    :lsid => "254.254.254.254",
    :advr => "253.253.253.253",
    :seqn => 0x12345678,
    :csum => 0xdead,
    :length =>0xef 
  }).enc)
  assert_equal(0, header1 <=> header2)
end    
def test_compare_greater
  header1 = LSA_Header.new(Ospf::LSA_Header.new({:length=>0xffff,
    :lsage => 1,
    :options => 0xee,
    :lstype => 0xdd,
    :lsid => "254.254.254.254",
    :advr => "253.253.253.253",
    :seqn => 0x12345678,
    :csum => 0xdead,
    :length =>0xef 
  }).enc)
  header2 = LSA_Header.new(Ospf::LSA_Header.new(
  {:length=>0xffff,
    :lsage => 222,
    :options => 0xee,
    :lstype => 0xbb,
    :lsid => "251.254.254.254",
    :advr => "253.253.253.253",
    :seqn => 0x12345678,
    :csum => 0xdead,
    :length =>0xef 
  }).enc)
  assert_equal(1, header1 <=> header2)
end    
def test_compare_smaller
  header1 = LSA_Header.new(Ospf::LSA_Header.new({:length=>0xffff,
    :lsage => 1,
    :options => 0xee,
    :lstype => 0xdd,
    :lsid => "254.254.254.254",
    :advr => "253.253.253.253",
    :seqn => 0x12345678,
    :csum => 0xdead,
    :length =>0xef 
  }).enc)
  header2 = LSA_Header.new(Ospf::LSA_Header.new(
  {:length=>0xffff,
    :lsage => 2,
    :options => 0xdd,
    :lstype => 0xbb,
    :lsid => "254.254.254.254",
    :advr => "253.255.255.253",
    :seqn => 0x12345678,
    :csum => 0xdead,
    :length =>0xef 
  }).enc)
  assert_equal(1, header1 <=> header2)
end    
