
require 'set'
require 'ie/id'
require 'ls_db/links'
module OSPFv2::LSDB
  class LinkStateDatabase
    include OSPFv2
    include OSPFv2::Common


    def add_adjacency(*arg)
      if arg.size==1 and arg[0].is_a?(Hash)
        arg = arg[0]
        router_id = arg[:router_id]
        neighbor_id = arg[:neighbor_router_id]
        prefix = arg[:prefix]
        metric = arg[:metric] ||= 1
        link = arg[:link] if arg[:link] and arg[:link].is_a?(Link)
      elsif arg.size>2
        router_id, neighbor_id, prefix, metric = arg
        metric ||=1
      else
        raise ArgumentError
      end
      
      raise ArgumentError, "missing neighbor router id" unless neighbor_id
      raise ArgumentError, "missing neighbor router id" unless router_id
      
      _, addr, plen, network, netmask = IPAddr.to_ary(prefix)
      advertised_routers + router_id
      rlsa = lookup(1,router_id)
      rlsa = self << { 
        :advertising_router=> router_id, 
        :ls_id=> router_id, :nwveb=>2, 
        :ls_type=>:router_lsa, 
        :options=> 0x22 } unless rlsa
      rlsa.delete(1,neighbor_id)
      rlsa.delete(3,network)
      rlsa << { :link_id=>neighbor_id, :link_data=>addr, :router_link_type=>:point_to_point, :metric=>metric, }
      rlsa << { :link_id=>network, :link_data=>netmask, :router_link_type=>:stub_network, :metric=>metric }
      rlsa
    end
    
    def remove_adjacency(rid, neighbor_id, prefix)
      if (rlsa = lookup(:router_lsa, rid))
        addr, source_address, plen, network, netmask = IPAddr.to_ary(prefix)
        rlsa.delete(:point_to_point,id2ip(neighbor_id))
        rlsa.delete(3,network)
      end
      rlsa
    end
    
    # :router_id=> 1, :link_id=> '192.168.0.1', :link_data => '255.255.255.255'
    # :router_id=> 1, :network=> '192.168.0.1/24', :metric => 10
    def add_link_to_stub_network(arg={})

      router_id = arg[:router_id]
      link_id = arg[:link_id]
      link_data = arg[:link_data]
      
      if arg[:network]
        addr = IPAddr.new arg[:network]
        link_id = addr.to_s
        link_data = addr.netmask
      end

      raise ArgumentError, "missing neighbor router id" unless router_id
      raise ArgumentError, "missing neighbor link_id" unless link_id
      raise ArgumentError, "missing neighbor link_data" unless link_data

      metric = arg[:metric] ||=0
      
      link = arg[:link] if arg[:link] and arg[:link].is_a?(Link)

      rlsa = lookup(1,router_id)
      link =  {:router_link_type=>:stub_network, :metric=>metric, :link_id=>link_id, :link_data=>link_data}
      if ! rlsa
        rlsa = self <<  {
          :advertising_router=> router_id,
          :ls_id=> router_id,
          :nwveb=>2, 
          :ls_type=>:router_lsa,
          :options=> 0x22,
        }
        advertised_routers + router_id
      end
      
      rlsa = lookup(1,router_id)
      rlsa.delete(3,link_id)
      rlsa  << link
      rlsa
    end
    alias :add_loopback :add_link_to_stub_network
    
  end
end
