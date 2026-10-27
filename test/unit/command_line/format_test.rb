# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/command_line/format'

# Route table output from hand-made view data.
class TestCommandLineFormat < Test::Unit::TestCase
  F = OSPFv2::CommandLine::Format

  def hop(gw = '10.0.0.2') = { 'interface' => 'eth0', 'gateway' => gw }

  def router(rid, abr, asbr)
    { 'router_id' => rid, 'prefix' => "#{rid}/32", 'path_type' => 'intra', 'cost' => 10, 'area' => '0.0.0.0',
      'next_hops' => [hop], 'advr' => rid, 'abr' => abr, 'asbr' => asbr }
  end

  def data
    { 'routers' => [router('2.2.2.2', true, false), router('3.3.3.3', false, true), router('4.4.4.4', true, true)],
      'routes' => [{ 'prefix' => '0.0.0.0/0', 'path_type' => 'ext2', 'cost' => 10, 'type2_cost' => 20, 'area' => nil,
                     'next_hops' => [hop], 'advr' => '3.3.3.3', 'tag' => 7, 'forwarding' => nil }] }
  end

  def test_router_kinds_never_print_false
    junos = F.render(:routes, :junos, data)
    assert_match(/^2\.2\.2\.2\s+Intra Area BR\s/, junos)
    assert_match(/^3\.3\.3\.3\s+Intra AS BR\s/, junos)
    assert_match(%r{^4\.4\.4\.4\s+Intra Area/AS BR\s}, junos)
    ios = F.render(:routes, :ios, data)
    assert_match(/2\.2\.2\.2\s+\[10\] area: 0\.0\.0\.0, ABR$/, ios)
    assert_match(/3\.3\.3\.3\s+\[10\] area: 0\.0\.0\.0, ASBR$/, ios)
    assert_match(/4\.4\.4\.4\s+\[10\] area: 0\.0\.0\.0, ABR, ASBR$/, ios)
    assert_no_match(/false/, junos + ios)
  end

  def test_external_detail_has_no_area
    out = F.render(:routes, :junos, data, detail: true)
    assert_match(%r{^0\.0\.0\.0/0\s+Ext2\s+Network\s+IP\s+20 eth0\s+10\.0\.0\.2\n  origin 3\.3\.3\.3, type 2 metric 20, internal 10, tag 7$}, out)
    assert_match(/N E2 0\.0\.0\.0\/0\s+\[10\/20\] tag: 7/, F.render(:routes, :ios, data))
    assert_match(%r{^O E2     0\.0\.0\.0/0 \[110/20\] via 10\.0\.0\.2, eth0$}, F.render(:routes, :ios_rib, data))
  end
end
