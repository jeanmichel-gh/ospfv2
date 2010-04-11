
require 'set'
require 'ie/id'
require 'ls_db/links'

require 'ls_db/link_state_database'

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
      
      raise ArgumentError, "missing prefix" unless prefix
      raise ArgumentError, "missing neighbor router id" unless neighbor_id

      _, addr, plen, network, netmask = IPAddr.to_ary(prefix)

      # if not set assume router id is the interface address given to us in :prefix
      router_id ||= addr
      

      # router_id to list of advertised routers
      advertised_routers + router_id

      rlsa = find_router_lsa router_id

      if ! rlsa

        # We need to build a router lsa
         rlsa = OSPFv2::Lsa.factory \
         :advertising_router=> router_id, 
         :ls_id=> router_id,
         :ls_type=>:router_lsa, 
         :options=> 0x22
         
        advertised_routers + router_id

        # add to lsdb
        self << rlsa
        
      else

        # delete any exisiting p2p and stub network 
        rlsa.delete(1,neighbor_id)
        rlsa.delete(3,network)

      end

      # Add a new router-link and stub network that describes the adjacency
      rlsa << { :link_id=>neighbor_id, :link_data=>addr, :router_link_type=>:point_to_point, :metric=>metric, }      
      rlsa << { :link_id=>network, :link_data=>netmask, :router_link_type=>:stub_network, :metric=>metric }

      rlsa

    end
    alias :add_p2p_adjacency :add_adjacency
    
    
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
      
      # link = arg[:link] if arg[:link] and arg[:link].is_a?(RouterLink)

      rlsa = find_router_lsa(router_id)

      link =  {:router_link_type=>:stub_network, :metric=>metric, :link_id=>link_id, :link_data=>link_data}
      if ! rlsa

        # build a router lsa with a stub network
         rlsa = OSPFv2::Lsa.factory \
          :advertising_router=> router_id,
          :ls_id=> router_id,
          :nwveb=>2, 
          :ls_type=>:router_lsa,
          :options=> 0x22
        
        advertised_routers + router_id
        
        # add to lsdb
        self << rlsa
        
      end
      
      # replace or add new stub router link
      rlsa = find_router_lsa(router_id)
      rlsa.delete(3,link_id)
      rlsa  << link
      rlsa
    end
    
    #
    # Router ID: 13.11.13.11
    # 
    # Router  *13.11.13.11      13.11.13.11      0x80000022   458  0x22 0x58e9  36
    #   bits 0x0, link count 1
    #   id 192.168.1.200, data 192.168.1.200, Type Transit (2)
    #     Topology count: 0, Default metric: 10
    #
    def add_router_id(router_id)
      add_link_to_stub_network :router_id => router_id, :link_id=> router_id, :link_data=> router_id
    end
    
    # Router  *13.11.13.11      13.11.13.11      0x80000032    16  0x22 0xf55e  48
    #   bits 0x0, link count 1
    #   id 99.99.1.1, data 255.255.255.255, Type Stub (3)
    #     Topology count: 0, Default metric: 0
    #     
    def add_loopback(arg={})
      add_link_to_stub_network :router_id => arg[:router_id], :link_id=> arg[:address], :link_data=> '255.255.255.255'
    end
    
  end

end

load "../../../test/ospfv2/ls_db/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
