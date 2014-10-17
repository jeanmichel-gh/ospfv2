require "test/unit"

require "infra/ospf_common"

class TestCommon < Test::Unit::TestCase
  def test_class_string_to__
    assert_equal 'camel_case', "CamelCase".to_underscore
    assert_equal 'router_id', "RouterId".to_underscore
    assert_equal 'area_id', "AreaId".to_underscore
    assert_equal 'ospf_bdr', "OspfBdr".to_underscore
    assert_equal 'ospf_dr', "OspfDr".to_underscore
    assert_equal 'as_external7', "AsExternal7".to_underscore
  end
  def test_class_string_to_camel
    assert_equal 'CamelCase', 'camel_case'.to_camel
    assert_equal 'RouterId', 'router_id'.to_camel
    assert_equal 'AreaId', 'area_id'.to_camel
  end
  def test_class_symbol_to_klass
    assert_equal :AnInstanceVar, :an_instance_var.to_klass
    assert_equal :AreaId, :area_id.to_klass
    assert_equal :RouterId, :router_id.to_klass
  end
  def test_attr_writer_delegate
  end
  def test_ipaddr
    assert_equal IPAddr, IPAddr.to_arr('10.0.0.1/24')[0].class
    assert_equal '10.0.0.1', IPAddr.to_arr('10.0.0.1/24')[1]
    assert_equal 24, IPAddr.to_arr('10.0.0.1/24')[2]
    assert_equal '10.0.0.0', IPAddr.to_arr('10.0.0.1/24')[3]
    assert_equal '255.255.255.0', IPAddr.to_arr('10.0.0.1/24')[4]
    assert_equal '10.0.0.8/30', IPAddr.new('10.0.0.0/30') ^ 2
    assert_equal '10.0.0.12/30', IPAddr.new('10.0.0.0/30') ^ 3
    assert_equal '10.0.0.1/30', IPAddr.new('10.0.0.0/30') + 1
    assert_equal '10.0.0.2/30', IPAddr.new('10.0.0.0/30') + 2
    assert_raise(NoMethodError)  { IPAddr.new('10.0.0.0/30') -1 }
    
    assert_equal '10.0.0.0', IPAddr.new('10.0.0.1/24').to_s
    assert_equal '10.0.0.0/24', IPAddr.new('10.0.0.1/24').to_s_net
    
  end
end