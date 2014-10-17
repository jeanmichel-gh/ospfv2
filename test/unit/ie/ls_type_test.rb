
require "test/unit"
require 'ie/ls_type'


class TestIeLsType < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert LsType.new :router
    assert_equal 'LsType: router', LsType.new(:router).to_s
    assert_equal 'LsType: network', LsType.new(:network).to_s
    assert_equal 'LsType: summary', LsType.new(:summary).to_s
    assert_equal 'LsType: asbr_summary', LsType.new(:asbr_summary).to_s
    assert_equal 'LsType: as_external', LsType.new(:as_external).to_s
    assert_equal 'LsType: link_local', LsType.new(:link_local).to_s
    assert_equal 'LsType: domain', LsType.new(:domain).to_s
    assert_equal 'LsType: area', LsType.new(:area).to_s
    assert_equal 1, LsType.new(:router).to_i
    assert_equal 2, LsType.new(:network).to_i
    assert_equal 3, LsType.new(:summary).to_i
    assert_equal 4, LsType.new(:asbr_summary).to_i
    assert_equal 5, LsType.new(:as_external).to_i
    assert_equal 9, LsType.new(:link_local).to_i
    assert_equal 10, LsType.new(:area).to_i
    assert_equal 11, LsType.new(:domain).to_i
    assert_equal :router, LsType.new(1).to_sym
    assert_equal :summary, LsType.new(3).to_sym
    assert_equal :network, LsType.new(2).to_sym
    assert_equal :asbr_summary, LsType.new(4).to_sym
    assert_equal :as_external, LsType.new(5).to_sym
    assert_equal :link_local, LsType.new(9).to_sym
    assert_equal :area, LsType.new(10).to_sym
    assert_equal :domain, LsType.new(11).to_sym
    assert LsType.new(:link_local).is_opaque?
    assert ! LsType.new(:router).is_opaque?
    assert LsType.new(:area).is_opaque?
    assert_equal 'OpaqLoca', LsType.new(:link_local).to_junos
    assert_equal 'Network', LsType.new(:network).to_junos
  end
end

