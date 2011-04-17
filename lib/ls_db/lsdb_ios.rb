module OSPFv2::LSDB
module Ios
  def _to_s_hdr_ios
    s=[]
    s << ""
    s << "            OSPF Router with ID ()"
    s
  end
  def _to_s_hdr_router_ios(verbose=false)
    s=[]
    s << ""
    s << "                Router Link States (Area #{area_id.to_i})"
    s << ""
    s << "Link ID         ADV Router      Age         Seq#       Checksum Link count" unless verbose
    s
  end
  def _to_s_hdr_network_ios(verbose=false)
    s=[]
    s << ""
    s << "                Net Link States (Area #{area_id.to_i})"
    s << ""
    s << "Link ID         ADV Router      Age         Seq#       Checksum" unless verbose
    s
  end
  def _to_s_hdr_summary_ios(verbose=false)
    s=[]
    s << ""
    s << "                Summary Net Link States (Area #{area_id.to_i})"
    s << ""
    s << "Link ID         ADV Router      Age         Seq#       Checksum" unless verbose
    s
  end
  def _to_s_hdr_asbr_summary_ios(verbose=false)
    s=[]
    s << ""
    s << "                Summary ASB Link States (Area #{area_id.to_i})"
    s << ""
    s << "Link ID         ADV Router      Age         Seq#       Checksum" unless verbose
    s
  end
  def _to_s_hdr_as_external_ios(verbose=false)
    s=[]
    s << ""
    s << "                Type-5 AS External States (Area #{area_id.to_i})"
    s << ""
    s << "Link ID         ADV Router      Age         Seq#       Checksum Tag" unless verbose
    s
  end
end
end