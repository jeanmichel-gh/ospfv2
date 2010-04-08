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
      if args.size==1 and args[0].is_a?(Hash)
        link = Link.new args[0]        
      elsif args[0].is_a?(Link)
        link = args[0]
      else
        raise ArgumentError, "invalid argument: #{args.inspect}"
      end

      dir = args[0][:direction] ||= :both
      local = false  if dir and dir == :remote_only
      remote = false if dir and dir == :local_only

      local_lsa  = add_loopback(:router_id=> link.router_id.to_i, 
      :network => link.local_prefix, 
      :metric=> 10) if dir != :remote_only 
      remote_lsa = add_loopback(:router_id=> link.neighbor_id.to_i, 
      :network => link.remote_prefix, 
      :metric=>10) if dir !=:local_only

      local_lsa.lsdb_link_id = link.id if local_lsa
      remote_lsa.lsdb_link_id = link.id if remote_lsa

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
    
    # def link_up(link, what=:both, refresh=[true,true])
    #   raise ArgumentError, "expecting a Link or TE_Link object", caller unless link.is_a?(Link)
    #   addr, source_address, plen, network, netmask = IPAddr.to_ary(link.prefix)
    #   local = (what == :local or what == :both)
    #   remote = (what == :remote or what == :both)
    #   local_rlsa, remote_rlsa = nil, nil        
    #   local_rlsa = add_adjacency(link.rid, link.nid, addr.host(1), link.metric[0])  if local
    #   remote_rlsa = add_adjacency(link.nid, link.rid, addr.host(2), link.metric[1]) if remote
    #   link.lsas = [local_rlsa, remote_rlsa]
    #   lss=[]    
    #   link.lsas.each_with_index do |lsa,ind|
    #     next if lsa.nil?
    #     lss << (refresh[ind] ? lsa.refresh  : lsa) 
    #   end
    #   flood(lss)
    # end

    def link_down
    end

    def link_refresh
    end

    def link_maxage
    end

  end
 
end

# FIXME: when ls_db is emtpty, got that:
#    OSPF link state database, Area 0.0.0.0
# Type       ID               Adv Rtr           Seq      Age  Opt  Cksum  Len 

if __FILE__ == $0

  require "test/unit"

  # require "ls_db/link_add"

  class TestLsDbLinks < Test::Unit::TestCase
    include OSPFv2::LSDB
    def setup
      @ls_db = LinkStateDatabase.new(:area_id=> 0)
    end
    def test_new_link
      @ls_db = LinkStateDatabase.new :area_id=>0
      @ls_db.new_link :router_id=> 1, :neighbor_id=>2
      @ls_db.new_link :router_id=> 1, :neighbor_id=>3
      @ls_db.new_link :router_id=> 1, :neighbor_id=>4
      @ls_db.new_link :router_id=> 1, :neighbor_id=>5
      # puts @ls_db.to_s_summary
    end
    def test_new_link_local_only
      @ls_db = LinkStateDatabase.new :area_id=>0
      @ls_db.new_link :router_id=> 1, :neighbor_id=>2, :direction => :local_only
      @ls_db.new_link :router_id=> 1, :neighbor_id=>3, :direction => :local_only
      @ls_db.new_link :router_id=> 1, :neighbor_id=>4, :direction => :local_only
      @ls_db.new_link :router_id=> 1, :neighbor_id=>5, :direction => :local_only
      assert_equal 1,  @ls_db.size
      assert_equal 1,  @ls_db.all_router[0].advertising_router.to_i
    end
    def test_new_link_remote_only
      @ls_db = LinkStateDatabase.new :area_id=>0
      @ls_db.new_link :router_id=> 1, :neighbor_id=>2, :direction => :remote_only
      @ls_db.new_link :router_id=> 1, :neighbor_id=>3, :direction => :remote_only
      @ls_db.new_link :router_id=> 1, :neighbor_id=>4, :direction => :remote_only
      @ls_db.new_link :router_id=> 1, :neighbor_id=>5, :direction => :remote_only
      assert_equal 4,  @ls_db.size
    end
    def test_link_up_down
      @ls_db = LinkStateDatabase.new :area_id=>0
      assert_equal 0, @ls_db.size
      @ls_db.new_link :router_id=> 1, :neighbor_id=>2
      assert_equal 2, @ls_db.size
      @ls_db.link Link.all[1], :up
      assert_equal 4, @ls_db.size
    end

    def test_create
      ls_db = LinkStateDatabase.create :columns=> 1, :rows=> 2, :base_prefix => '169.0.0.0/24', :base_router_id=> 0x80000000
      assert_equal 2, ls_db.size
      #puts ls_db
      # 128.2.0.1  x.R.x.C   (2,1)
      # 128.1.0.1            (1,1)

    end
 
  end

end
