require "test/unit"

require "ls_db/links"

class TestLsDbLinks < Test::Unit::TestCase
  include OSPFv2::LSDB
  def setup
    Link.reset
  end
  def test_link_count
    assert_equal 0, Link.count
    assert link = Link.new
    assert link = Link.new
    assert link = Link.new
    assert_equal 3, Link.count
    assert_equal 3, Link.all.size
    assert_equal [1,2,3], Link.ids
  end
  def test_base_addr
    assert Link.base_ip_addr.is_a?(IPAddr)
    assert_equal '13.0.0.0', Link.base_ip_addr.to_s
  end
  def test_new_from_hash
    assert_equal '0.0.0.1', Link.new( :router_id=> 1, :neighbor_id=>2).to_hash[:router_id]
    assert_equal '0.0.0.2', Link.new( :router_id=> 1, :neighbor_id=>2).to_hash[:neighbor_id]
    assert_equal 10, Link.new( :metric => 10).to_hash[:metric]
    assert_equal '10.0.0.0/24', Link.new( :prefix => '10.0.0.0/24').to_hash[:prefix]
  end
  def test_address
    assert_equal '13.0.0.1/30', (l1 = Link.new).local_prefix
    assert_equal '13.0.0.6/30', (l2 = Link.new).remote_prefix
  end
  def test_array_of_links
    arr = (1..10).inject([]) { |arr,i| arr << Link.new(:metric=> i)  }
    assert_equal 10, arr.size
    assert_equal 7, arr[6].metric.to_i
    assert_equal '13.0.0.25/30', arr[6].local_prefix
    assert_equal '13.0.0.26/30', arr[6].remote_prefix
    assert_equal '13.0.0.25', arr[6].local_address
    assert_equal '13.0.0.26', arr[6].remote_address
  end
  def test_find_by_id
    arr = (1..2).inject([]) { |arr,i| arr << Link.new( :router_id=> 1, :neighbor_id=>2)  }
    arr = (2..3).inject([]) { |arr,i| arr << Link.new( :router_id=> 2, :neighbor_id=>3)  }
    arr = (3..4).inject([]) { |arr,i| arr << Link.new( :router_id=> 3, :neighbor_id=>4)  }
    # puts Link.all.values.join("\n")
    assert_equal 2, Link.find_by_id('0.0.0.1').size
  end
end
