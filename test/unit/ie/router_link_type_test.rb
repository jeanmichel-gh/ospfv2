
require "test/unit"
require 'ie/router_link_type'


class TestIeRouterLinkType < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert RouterLinkType.new :point_to_point
    assert_equal 'RouterLinkType: point_to_point', RouterLinkType.new(:point_to_point).to_s
    assert_equal 'RouterLinkType: transit_network', RouterLinkType.new(:transit_network).to_s
    assert_equal 'RouterLinkType: stub_network', RouterLinkType.new(:stub_network).to_s
    assert_equal 'RouterLinkType: virtual_link', RouterLinkType.new(:virtual_link).to_s
    assert_equal 1, RouterLinkType.new(:point_to_point).to_i
    assert_equal 2, RouterLinkType.new(:transit_network).to_i
    assert_equal 3, RouterLinkType.new(:stub_network).to_i
    assert_equal 4, RouterLinkType.new(:virtual_link).to_i
    assert_equal :point_to_point, RouterLinkType.new(1).to_sym
    assert_equal :stub_network, RouterLinkType.new(3).to_sym
    assert_equal :transit_network, RouterLinkType.new(2).to_sym
    assert_equal :virtual_link, RouterLinkType.new(4).to_sym
  end
end

