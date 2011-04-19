
require 'neighbor/neighbor'
include OSPFv2

neighbor = Neighbor.new  :src_addr => '192.168.158.1', :router_id => 1

link_tlv = Link_Tlv.new

link_tlv << LinkType_Tlv.new
link_tlv << LinkId_Tlv.new(:link_id=>'1.2.3.4')
link_tlv << LocalInterfaceIpAddress_Tlv.new(:ip_address=>"1.1.1.1")
link_tlv << RemoteInterfaceIpAddress_Tlv.new(:ip_address=>"2.2.2.2")
link_tlv << TrafficEngineeringMetric_Tlv.new(:te_metric=>255)
link_tlv << MaximumBandwidth_Tlv.new(:max_bw=>10_000)
link_tlv << MaximumReservableBandwidth_Tlv.new(:max_resv_bw=>7_000)
link_tlv << UnreservedBandwidth_Tlv.new(:unreserved_bw=>[100]*8)

lsa =  TrafficEngineering.new :advertising_router=>1, :opaque_id=>0xff, :top_lvl_tlv=> link_tlv

neighbor.send LinkStateUpdate.new_lsas :router_id=> 1, :lsas => [lsa]
