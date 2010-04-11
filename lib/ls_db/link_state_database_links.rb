require 'ls_db/link_state_database'
require 'ls_db/links'
require 'lsa/lsa'

module OSPFv2


  class Lsa
    def lsdb_link_id
      @_lsdb_link_id
    end
    def lsdb_link_id=(val)
      @_lsdb_link_id= val
    end
    def find_lsa_from_link(id)
      all.find_all { |l| l.lsdb_link_id==id  }
    end
  end

end

module OSPFv2::LSDB

  class LinkStateDatabase

    def self.router_id(row, col, base_rid=ROUTER_ID_BASE)
      (row << 16) + col + base_rid      
    end

    def router_id(*args)
      LinkStateDatabase.router_id(*args)
    end  

    # lsdb = LinkStateDatabase.create 10, 10, :prefix => '192.168.0.0/24'
    # lsdb = LinkStateDatabase.create 10, 10, :prefix_base => '192.168.0.0/24', :router_id_base => 
    def self.create(arg={})
      arg = {:area_id=> 0, :columns=>2, :rows=>2, :base_router_id=> 0, :base_prefix=>'172.21.0.0/30'}.merge(arg)
      ls_db = new arg
      rows=arg[:rows]
      cols=arg[:columns]
      @base_router_id = arg[:base_router_id] 
      if arg[:base_prefix]
        Link.reset_ip_addr
        Link.base_ip_addr arg[:base_prefix]
      end
      @base_prefix = arg[:base_prefix]
      router_id = lambda { |c,r|  (r<<16) + c + @base_router_id }
      1.upto(rows) do |r|
        1.upto(cols) do |c|
          ls_db.new_link(:router_id=> router_id.call(c,r-1), :neighbor_id=> router_id.call(c,r)) if r > 1
          ls_db.new_link(:router_id=> router_id.call(c-1,r), :neighbor_id=> router_id.call(c,r)) if c > 1
        end
      end
      ls_db
    end

    # link, :dir => :local_only
    # link_hash, :direction => :remote_only

    def new_link(*args)

      # get a link object
      local, remote = true, true
      if args.size==1 and args[0].is_a?(Hash)
        link = Link.new args[0]
      elsif args[0].is_a?(Link)
        link = args[0]
      else
        raise ArgumentError, "invalid argument: #{args.inspect}"
      end
      
      # local, remote or both
      dir = args[0][:direction] ||= :both
      local = false  if dir and dir == :remote_only
      remote = false if dir and dir == :local_only
      
      if local
        lsa = add_p2p_adjacency :router_id => link.router_id.to_i, :neighbor_router_id => link.neighbor_id.to_i, :prefix => link.local_prefix, :metric=>1
        lsa.lsdb_link_id = link.id
        link.local_lsa = lsa.key
      end

      if remote
        lsa = add_p2p_adjacency :router_id => link.neighbor_id.to_i, :neighbor_router_id => link.router_id.to_i, :prefix => link.remote_prefix, :metric=>1
        lsa.lsdb_link_id = link.id
        link.remote_lsa = lsa.key
      end
      
    end
    
    def link(link, action)
      raise ArgumentError, "invalid argument: #{link.class}" unless link.is_a?(Link)
      case action
      when :up   ; link_up(link)
      when :down ; link_down(link)
      end
    end

    def link_up(link)
      raise ArgumentError, "invalid argument: #{link.class}" unless link.is_a?(Link)
      add_adjacency :router_id=> link.router_id.to_i, 
                    :neighbor_router_id => link.neighbor_id.to_i, 
                    :prefix=> link.local_prefix, 
                    :metric => link.metric 
      add_adjacency :router_id=> link.neighbor_id.to_i, 
                    :neighbor_router_id => link.router_id.to_i, 
                    :prefix=> link.remote_prefix, 
                    :metric => link.metric      
    end

    def link_down(link)      
      lsa = @ls_db[link.local_lsa]
      lsa.delete(1, link.neighbor_id.to_ip)
      lsa = @ls_db[link.remote_lsa]
      lsa.delete(1, link.router_id.to_ip)
    end

    def link_refresh

    end

    def link_maxage

    end

  end
  
  # @ls_db = LinkStateDatabase.new :area_id=>0
  #  @ls_db.new_link :router_id=> 1, :neighbor_id=>2
  #  @ls_db.new_link :router_id=> 1, :neighbor_id=>3
  #  @ls_db.new_link :router_id=> 1, :neighbor_id=>4
  #  @ls_db.new_link :router_id=> 1, :neighbor_id=>5
  # 
  #  puts @ls_db
  #  
  #  # p Link[1]
  # 
  # rlsa =  @ls_db[1,1]
  # p rlsa.links.size
  # p rlsa
  # rlsa.delete(:point_to_point,'0.0.0.2')
  # p rlsa.links.size
  # 
  # rlsa =  @ls_db[1,2]
  # p rlsa.links.size
  # p rlsa
  # rlsa.delete(:point_to_point,'0.0.0.1')
  # p rlsa.links.size
  # 
  # puts @ls_db
  
 
end

load "../../../test/ospfv2/ls_db/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

