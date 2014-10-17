require "test/unit"
require 'lsa/router'

require "neighbor/neighbor"

class TestNeighborNeighbor < Test::Unit::TestCase
  include OSPFv2
  def test_states
    assert Neighbor.new
    assert_equal :down, Neighbor.new.state
    assert Neighbor.new.in_state?(:down)
    assert  ! Neighbor.new.in_state?(:full)
    assert Neighbor.new.in_state?(:full, :down)
  end
  
  def test_flood
    
    neighbor = Neighbor.new
    def neighbor.send(packet,dest)
      ret=[]
      [packet].flatten.each { |p| 
        ret << [p.class,dest]
      }
      ret
    end
    assert_equal [[String, "dest"]], neighbor.send( 'a packet', 'dest')
    assert_equal [[String, 'dest'], [String, 'dest']], neighbor.send( ['one','two'], 'dest')
    
    lsas = []
    lsas << Router.new
    lsas << Router.new
    
    assert_equal 1, neighbor.flood(:lsas =>lsas).size
    assert_equal [OSPFv2::LinkStateUpdate, "224.0.0.5"], neighbor.flood(:lsas =>lsas)[0]
  end
  
end

__END__


TODO:

require 'test/unit'
require 'ospfv2/neighbor'

class TestOspfv2Neighbor < Test::Unit::TestCase # :nodoc:
  def test_init
    neighbor = OSPFv2::Neighbor.new("1.1.1.1", "0.0.0.0", "10.0.0.1", {:netmask => '255.255.255.0', :options => 0x2})
    assert_equal(10,neighbor.helloInt)
    assert_equal(40,neighbor.deadInt)
    assert_equal("1.1.1.1",neighbor.router_id)
  end
  def test_hello_int
    neighbor = OSPFv2::Neighbor.new("1.1.1.1", "0.0.0.0", "10.0.0.1", {:netmask => '255.255.255.0', :options => 0x2})
    neighbor.set({:helloInt => 5,})
    assert_equal(5*4,neighbor.deadInt)
    neighbor.set({:deadInt => 45,})
    assert_equal(45,neighbor.deadInt)
    neighbor.set({:deadInt => 0,})
    assert_equal(20,neighbor.deadInt)
  end
  
  def test_states
    n = OSPFv2::Neighbor.new("1.1.1.1", "0.0.0.0", "10.0.0.1", {:netmask => '255.255.255.0', :options => 0x2})
    assert_equal(:Down,n.state?)
    assert_raise(NoMethodError) {n.newState}
    def n.set_state(state, comment="who cares")
      newState(state,comment)
      state?
    end
    def n.INFO(s); end
    assert_equal(:Down,n.state?)
    assert_equal(:Full,n.set_state(:Full))
    assert_equal(true,n.state?(:Full))
    assert_equal(true,n.state?(:Init, :Full, :Exchange))
    assert_equal(:Loading,n.set_state(:Loading))
    assert_equal(false,n.state?(:Init, :Full, :Exchange))
    assert_equal(true,n.state?(:Init, :Loading, :Exchange))
  end  
end

