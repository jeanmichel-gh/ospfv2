
require 'neighbor/neighbor'
include OSPFv2

neighbor = Neighbor.new  :src_addr => '192.168.158.1', :router_id => 1

link_tlv = Link_Tlv.new
@lsa1 =  TrafficEngineering.new :advertising_router=>1, :opaque_id=>0xff, :top_lvl_tlv=> link_tlv

link_tlv << LinkType_Tlv.new
link_tlv << LinkId_Tlv.new(:link_id=>'1.2.3.4')
link_tlv << LocalInterfaceIpAddress_Tlv.new(:ip_address=>"1.1.1.1")
link_tlv << RemoteInterfaceIpAddress_Tlv.new(:ip_address=>"2.2.2.2")
link_tlv << TrafficEngineeringMetric_Tlv.new(:te_metric=>255)
link_tlv << MaximumBandwidth_Tlv.new(:max_bw=>10_000)
link_tlv << MaximumReservableBandwidth_Tlv.new(:max_resv_bw=>7_000)
link_tlv << UnreservedBandwidth_Tlv.new(:unreserved_bw=>[100]*8)


link_tlv = {
  :tlv_type=>2,
  :tlvs=>
    [{:tlv_type=>1, :link_type=>1},
      {:tlv_type=>2, :link_id=>"5.6.7.8"},
      {:tlv_type=>3, :ip_address=>"11.11.11.11"},
      {:tlv_type=>4, :ip_address=>"22.22.22.22"},
      {:tlv_type=>5, :te_metric=>255},
      {:tlv_type=>6, :max_bw=>10000},
      {:tlv_type=>7, :max_resv_bw=>7000},
      {:tlv_type=>8, :unreserved_bw=>[100, 100, 100, 100, 100, 100, 100, 100]}]}

@lsa2 =  TrafficEngineering.new :sequence_number=> 2,
      :opaque_id=>0,:advertising_router=>1, :opaque_id=>0xff, :top_lvl_tlv=> link_tlv


@lsa3 = TrafficEngineering.new_hash( { 
  :sequence_number=>2147483649,
  :opaque_id=>0,
  :top_lvl_tlv=>
    {:tlvs=>
      [ {:link_type=>1, :tlv_type=>1},
        {:link_id=>"5.6.7.8", :tlv_type=>2},
        {:ip_address=>"111.111.111.111", :tlv_type=>3},
        {:ip_address=>"222.222.222.222", :tlv_type=>4},
        {:te_metric=>255, :tlv_type=>5},
        {:max_bw=>10000, :tlv_type=>6},
        {:max_resv_bw=>7000, :tlv_type=>7},
        {:unreserved_bw=>[100, 100, 100, 100, 100, 100, 100, 100], :tlv_type=>8}],
      :tlv_type=>2},
  :opaque_type=>:te_lsa,
  :ls_age=>0,
  :ls_type=>:area,
  :advertising_router=> 3,
  :options=>0})

neighbor.send LinkStateUpdate.new_lsas :router_id=> 1, :lsas => [lsa1, lsa2, lsa3]

