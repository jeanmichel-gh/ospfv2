require 'ls_db/link_state_database_links'
require "test/unit"

# require "ls_db/link_add"

class TestLsDbLinks < Test::Unit::TestCase
  include OSPFv2::LSDB
  def setup
    @ls_db = LinkStateDatabase.new(:area_id=> 0)
    Link.reset
  end
  def test_new_link
    ls_db = LinkStateDatabase.new :area_id=>0
    ls_db.new_link :router_id=> 1, :neighbor_id=>2
    ls_db.new_link :router_id=> 1, :neighbor_id=>3
    ls_db.new_link :router_id=> 1, :neighbor_id=>4
    ls_db.new_link :router_id=> 1, :neighbor_id=>5

    Link.all.values.each { |lnk| ls_db.link lnk, :down  }
    Link.all.values.each { |lnk| ls_db.link lnk, :up  }

    rlsa.delete(:point_to_point,'0.0.0.2')
    assert_equal 7, rlsa.links.size      
    puts ls_db
    rlsa.delete(:point_to_point,'0.0.0.3')
    rlsa.delete(:point_to_point,'0.0.0.4')
    rlsa.delete(:point_to_point,'0.0.0.5')
    assert_equal 4, rlsa.links.size
    assert_equal 5, ls_db.size
    ls_db.link Link[1], :down
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

  def test_create
    ls_db = LinkStateDatabase.create :columns=> 2, :rows=> 2, 
    :base_prefix => '169.0.0.0/24', 
    :base_router_id=> 0x80000000
    assert_equal 4, ls_db.size
    assert  ls_db[1,'128.1.0.1'].has_link?(3,'169.0.0.0')
    assert  ls_db[1,'128.1.0.2'].has_link?(3,'169.0.2.0')
  end
  
  def test_create_empty_database
    ls_db = LinkStateDatabase.create :columns=> 0, :rows=> 0
    assert_equal 0, ls_db.size
    
    
    
    
    
  end





end
