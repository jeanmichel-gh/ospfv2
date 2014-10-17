require "test/unit"
require "packet/hello"

class TestHello < Test::Unit::TestCase
  include OSPFv2
  def test_neighbors
    assert Hello::Neighbors.new
    nbrs = Hello::Neighbors.new
    nbrs + '0.0.0.1'
    assert_equal 1, nbrs.ids[0]
    assert nbrs.has?'0.0.0.1'
    assert ! nbrs.has?('0.0.0.2')
    nbrs + '0.0.0.2'
    nbrs + '0.0.0.2'
    nbrs + '0.0.0.2'
    nbrs + '0.0.0.2'
    assert nbrs.has?('0.0.0.2')
    nbrs - '0.0.0.2'
    assert ! nbrs.has?('0.0.0.2')
    assert_equal '00000001', nbrs.to_shex
    nbrs + '0.0.0.2'
    assert_equal '0000000100000002', nbrs.to_shex
  end

  def test_new
    hh = {
      :netmask=> 0xffffffaa, 
      :designated_router_id=> '1.1.1.1', 
      :backup_designated_router_id=> '2.2.2.2', 
      :helloInt=>10, 
      :options=>2, 
      :rtr_pri=>0, 
      :deadInt=>40, 
      :neighbors=> ["1.1.1.1", "2.2.2.2", "3.3.3.3"] 
    }

    hello = Hello.new(hh)
    assert_equal 1, hello.packet_type.to_i
    assert_equal 'RouterId: 0.0.0.0',hello.router_id.to_s
    assert_equal Hello::Neighbors, hello.neighbors.class
    assert  hello.has_neighbor?('1.1.1.1')
    assert  hello.has_neighbor?('2.2.2.2')
    assert  hello.has_neighbor?('3.3.3.3')
    assert ! hello.has_neighbor?('1.1.1.4')
    assert_equal '020100380000000000000000e9d700000000000000000000ffffffaa000a0200000000280101010102020202010101010202020203030303', hello.to_shex
    hello.remove_neighbor '1.1.1.1'
    assert_equal '020100340000000000000000ebdd00000000000000000000ffffffaa000a02000000002801010101020202020202020203030303', hello.to_shex
    hello.remove_neighbor '3.3.3.3'
    assert_equal '020100300000000000000000f1e700000000000000000000ffffffaa000a020000000028010101010202020202020202', hello.to_shex
  end
  
  
  def test_1
    s = "0201002c 0aff 0801 0000 0000 0000 0000 0000 0000 0000 0000 ffff ff00  000a 0280 0000 0028 0000 0000 0000 0000".split.join
    hello = OSPFv2::Hello.new([s].pack('H*'))
    assert_equal("0201002c0aff080100000000e91f00000000000000000000ffffff00000a0280000000280000000000000000",hello.to_shex)
    assert_equal("0.0.0.0",hello.to_hash[:designated_router_id])
    assert_equal("0.0.0.0",hello.to_hash[:backup_designated_router_id])
    assert_equal(2,hello.options.to_i)
    assert_equal(128,hello.to_hash[:rtr_pri])
    assert_equal(10,hello.to_hash[:hello_interval])
    assert_equal(40,hello.to_hash[:router_dead_interval])
    assert_equal(Hello::Neighbors,hello.to_hash[:neighbors].class)
    hello =  OSPFv2::Hello.new
    hello.neighbors= "1.1.1.1"
    hello.neighbors= "2.2.2.2"
    hello.neighbors= "3.3.3.3"
    assert_equal(3,hello.to_hash[:neighbors].ids.size)
    
    hello2 = OSPFv2::Hello.new(hello.encode)
    assert_equal hello2.to_shex, hello.to_shex
    assert_equal(hello2.encode, hello.encode)
    assert_equal(hello2.to_s, hello.to_s)
    
  end
  
  def test_has_neighbor?
    hello =  OSPFv2::Hello.new
    assert ! hello.has_neighbor?('2.2.2.2')
    hello.neighbors= "1.1.1.1"
    hello.neighbors= "2.2.2.2"
    hello.neighbors= "3.3.3.3"
    # puts hello
    assert hello.has_neighbor?('2.2.2.2')
    assert hello.has_neighbor?('2.2.2.2')
    assert ! hello.has_neighbor?('4.4.4.4')
  end
  
  def test_add_neighbor
    hello1 = OSPFv2::Hello.new :router_id=>'1.1.1.1'
    hello2 = OSPFv2::Hello.new :router_id=>'2.2.2.2'
    hello2.neighbors=hello1.router_id.to_hash
    #puts hello2
  end
  def test_attr_delegate
    hello = OSPFv2::Hello.new
    assert_equal '0.0.0.0', hello.designated_router_id.to_ip
    hello.designated_router_id='1.1.1.1'
    hello.backup_designated_router_id='2.2.2.2'
    assert_equal OSPFv2::Hello::DesignatedRouterId, hello.designated_router_id.class
    assert_equal '1.1.1.1', hello.designated_router_id.to_ip
    assert_equal '2.2.2.2', hello.backup_designated_router_id.to_ip
    
  end
  
  
end
