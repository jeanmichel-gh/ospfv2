require "test/unit"

require "lsa/tlv/tlv_factory"

class TestLsaTlvTlvFactory < Test::Unit::TestCase
  include OSPFv2
  def test_router_address
    h = {:tlv_type=>1, :ip_address=>"1.1.1.1"}
    tlv = Tlv.factory(h)
    assert_equal(h, tlv.to_hash)
    assert_equal(h, Tlv.factory(tlv.to_hash).to_hash)
  end
  def test_link
    h = {
      :tlv_type=>2,
      :tlvs=> [
        {:tlv_type=>1, :link_type=>1},
        {:tlv_type=>2, :link_id=>"1.2.3.4"},
        {:tlv_type=>3, :ip_address=>"1.1.1.1"},
        {:tlv_type=>4, :ip_address=>"2.2.2.2"},
        {:tlv_type=>5, :te_metric=>255},
        {:max_bw=>10000, :tlv_type=>6},
        {:tlv_type=>7, :max_resv_bw=>0.0},
        {:tlv_type=>8, :unreserved_bw=>[100, 100, 100, 100, 100, 100, 100, 100]}
      ]}
    tlv = Tlv.factory(h)
    assert_equal(h, tlv.to_hash)
    assert_equal(h, Tlv.factory(tlv.to_hash).to_hash)
  end

end

class TestSubTlvFactory < Test::Unit::TestCase
  include OSPFv2
  def test_link_type_sub_tlv
    s = ['0001000101000000'].pack('H*')
    tlv = SubTlv.factory(s)
    assert_equal(LinkType_Tlv, tlv.class)
    assert_equal(s, tlv.encode)
    tlv = SubTlv.factory(:tlv_type=>1, :link_type=>1)
    assert_equal(LinkType_Tlv, tlv.class)
    assert_equal({:link_type=>1, :tlv_type=>1}, tlv.to_hash)
    assert_equal('0001000101000000', tlv.to_shex)
  end
  def test_link_id_sub_tlv
    s = ['0002000401020304'].pack('H*')
    tlv = SubTlv.factory(s)
    assert_equal(LinkId_Tlv, tlv.class)
    assert_equal(s, tlv.encode)
  end
  def test_local_interface_sub_tlv
    s = ['0003000401020304'].pack('H*')
    tlv = SubTlv.factory(s)
    assert_equal(LocalInterfaceIpAddress_Tlv, tlv.class)
    assert_equal(s, tlv.encode)
  end      
  def test_remote_interface_sub_tlv
    s = ['0004000401020304'].pack('H*')
    tlv = SubTlv.factory(s)
    assert_equal(RemoteInterfaceIpAddress_Tlv, tlv.class)
    assert_equal(s, tlv.encode)
  end   
  def test_te_metric_sub_tlv
    s = ['0005000400000064'].pack('H*')
    tlv = SubTlv.factory(s)
    assert_equal(TrafficEngineeringMetric_Tlv, tlv.class)
    assert_equal(s, tlv.encode)
  end
  def test_max_bw_sub_tlv
    s = ['000600043f800000'].pack('H*')
    tlv = SubTlv.factory(s)
    assert_equal(MaximumBandwidth_Tlv, tlv.class)
    assert_equal(s, tlv.encode)
  end
  def test_max_reserv_bw_sub_tlv
    s = ['000700043f800000'].pack('H*')
    tlv = SubTlv.factory(s)
    assert_equal(MaximumReservableBandwidth_Tlv, tlv.class)
    assert_equal(s, tlv.encode)
  end
  def test_unreserv_bw_sub_tlv
    s = ['000800203e0000003e8000003ec000003f0000003f2000003f4000003f6000003f800000'].pack('H*')
    tlv = SubTlv.factory(s)
    assert_equal(UnreservedBandwidth_Tlv, tlv.class)
    assert_equal(s, tlv.encode)
  end

end

