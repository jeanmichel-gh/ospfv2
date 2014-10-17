require "test/unit"

require "lsa/traffic_engineering"
require 'lsa/tlv/tlv_factory'

class TestLsaTlvTrafficEngineering < Test::Unit::TestCase
  include OSPFv2
  def test_new_from_hash
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
      lsa = TrafficEngineering.new_hash(h_lsa)
      assert_equal OSPFv2::TrafficEngineering, lsa.class
      assert_equal h_lsa, lsa.to_hash
  end
  
  def test_new_link_tlv
    link_tlv = Link_Tlv.new

    lsa =  TrafficEngineering.new :advertising_router=>1, :opaque_id=>0xff, :top_lvl_tlv=> link_tlv
    assert_equal('0000000a010000ff00000001800000011444001800020000', lsa.to_shex)

    link_tlv << LinkType_Tlv.new
    assert_equal('0000000a010000ff000000018000000171d30020000200080001000101000000', lsa.to_shex)
    link_tlv << LinkId_Tlv.new(:link_id=>'1.2.3.4')
    assert_equal('0000000a010000ff0000000180000001ec3800280002001000010001010000000002000401020304', lsa.to_shex)
    link_tlv << LocalInterfaceIpAddress_Tlv.new(:ip_address=>"1.1.1.1")
    assert_equal('0000000a010000ff000000018000000150b9003000020018000100010100000000020004010203040003000401010101', lsa.to_shex)
    link_tlv << RemoteInterfaceIpAddress_Tlv.new(:ip_address=>"2.2.2.2")
    link_tlv << TrafficEngineeringMetric_Tlv.new(:te_metric=>255)
    link_tlv << MaximumBandwidth_Tlv.new(:max_bw=>10_000)
    link_tlv << MaximumReservableBandwidth_Tlv.new(:max_resv_bw=>7_000)
    link_tlv << UnreservedBandwidth_Tlv.new(:unreserved_bw=>[100]*8)
    
  end
  
  def test_new_router_address_tlv
    router_address = RouterAddress_Tlv.new(:ip_address=>'1.2.3.4')
    lsa =  TrafficEngineering.new :advertising_router=>1, :opaque_id=>0xff, :top_lvl_tlv=> router_address
    assert_equal('0000000a010000ff00000001800000018abc001c0001000401020304', lsa.to_shex)

    lsa =  TrafficEngineering.new :advertising_router=>'255.255.255.255', 
                                  :opaque_id=>0xdeadff, 
                                  :top_lvl_tlv=> { :tlv_type=> 1, :ip_address=> '10.11.12.13'}
    assert_equal('0000000a01deadffffffffff80000001dabc001c000100040a0b0c0d', lsa.to_shex)
    
  end
  
end