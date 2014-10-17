require "test/unit"
require "ie/router_link_factory"

class TestIeRouterLinkFactory < Test::Unit::TestCase
  include OSPFv2
  def tests
    assert_equal RouterLink::PointToPoint,   (l1=RouterLink.factory(['000000000000000001000000'].pack('H*'))).class
    assert_equal RouterLink::StubNetwork,    (l2=RouterLink.factory(['000000000000000003000000'].pack('H*'))).class
    assert_equal RouterLink::VirtualLink,    (l3=RouterLink.factory(['000000000000000004000000'].pack('H*'))).class
    assert_equal RouterLink::TransitNetwork, (l4=RouterLink.factory(['000000000000000002000000'].pack('H*'))).class
    assert_equal RouterLink::TransitNetwork, (l5=RouterLink.factory(['0000000000000000020100000a000014'].pack('H*'))).class
    assert_raise(ArgumentError) { RouterLink.factory(:link_id=> '1.1.1.1') }
    assert_equal RouterLink::PointToPoint, RouterLink.factory(:link_data=> '1.1.1.1', :router_link_type => :point_to_point).class
    assert_equal RouterLink::TransitNetwork, RouterLink.factory(:link_data=> '1.1.1.1', :router_link_type => :transit_network).class
    assert_equal RouterLink::StubNetwork, RouterLink.factory(:link_data=> '1.1.1.1', :router_link_type => :stub_network).class
    assert_equal RouterLink::VirtualLink, RouterLink.factory(:link_data=> '1.1.1.1', :router_link_type => :virtual_link).class
    l1h = RouterLink.factory :router_link_type=>:point_to_point, :metric=>0, :tos_metrics=>[], :link_id=>"0.0.0.0", :link_data=>"0.0.0.0"
    assert_equal l1h.to_shex , l1.to_shex
    l1h = RouterLink.factory :router_link_type=>:point_to_point,  :tos_metrics=>[], :link_id=>"0.0.0.0", :link_data=>"0.0.0.0"
    assert_equal l1.to_shex, l1h.to_shex 
    l1h = RouterLink::PointToPoint.new :router_link_type=>:point_to_point,  :tos_metrics=>[], :link_id=>"0.0.0.0", :link_data=>"0.0.0.0"
    assert_equal l1.to_shex, l1h.to_shex
    assert_equal l1.to_hash, l1h.to_hash
  end
end

