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
  end

  def gw(ip, dev = 'eth0') = { 'interface' => dev, 'gateway' => ip }

  def fib
    { 'configured' => true, 'install' => true, 'protocol' => 89, 'table' => 254, 'metric' => 20,
      'routes' => [
        { 'prefix' => '2.2.2.2/32', 'state' => 'installed', 'want' => [gw('10.0.0.2')], 'have' => [gw('10.0.0.2')],
          'path_type' => 'intra', 'cost' => 10 },
        { 'prefix' => '3.3.3.3/32', 'state' => 'failed', 'error' => 'Network is unreachable', 'want' => [gw('10.0.0.3')],
          'have' => nil, 'path_type' => 'intra', 'cost' => 20 },
        { 'prefix' => '8.0.0.0/8', 'state' => 'held', 'want' => nil, 'have' => [gw('10.0.0.2')] },
        { 'prefix' => '9.0.0.0/8', 'state' => 'different', 'want' => [gw('10.0.0.2'), gw('10.0.1.2', 'eth1')],
          'have' => [gw('10.0.0.9')], 'path_type' => 'ext2', 'cost' => 10, 'type2_cost' => 20 }
      ] }
  end

  def test_junos_show_route_protocol_ospf
    out = F.render(:fib, :junos, fib)
    assert_match(/\Ainet\.0: 4 destinations, 4 routes \(3 active, 0 holddown, 0 hidden\)/, out)
    assert_match(%r{^2\.2\.2\.2/32\s+\*\[OSPF/10\] metric 10\n\s+>  to 10\.0\.0\.2 via eth0$}, out)
    assert_match(%r{^3\.3\.3\.3/32\s+ \[OSPF/10\] metric 20\n\s+  to 10\.0\.0\.3 via eth0\n\s+not installed: Network is unreachable$}, out)
    assert_match(%r{^8\.0\.0\.0/8\s+\*\[OSPF/10\]\n.*\n\s+kept from before a restart}, out)
    assert_match(%r{^9\.0\.0\.0/8\s+\*\[OSPF/150\] metric 20\n\s+>  to 10\.0\.0\.9 via eth0\n\s+the kernel has via 10\.0\.0\.9 eth0$}, out)
    assert_equal 'OSPF routes are not installed (routing-options kernel no-install)',
                 F.render(:fib, :junos, fib.merge('install' => false))
    assert_match(/^table 1000: /, F.render(:fib, :junos, fib.merge('table' => 1000)))
  end

  def test_ios_show_ip_route_ospf
    out = F.render(:fib, :ios, fib)
    assert_match(%r{^O        2\.2\.2\.2/32 \[110/10\] via 10\.0\.0\.2, eth0$}, out)
    assert_match(%r{^O E2     9\.0\.0\.0/8 \[110/20\] via 10\.0\.0\.9, eth0$}, out)
    assert_match(%r{^O        8\.0\.0\.0/8 \[110/-\] via 10\.0\.0\.2, eth0$}, out)
    assert_no_match(%r{^O.*3\.3\.3\.3}, out, 'not in the kernel, not in the table')
    assert_match(%r{^% 3\.3\.3\.3/32 not installed: Network is unreachable$}, out)
    assert_match(/^% OSPF routes are not installed: cannot open/, F.render(:fib, :ios, fib.merge('error' => 'cannot open the kernel routing table: x')))
  end

  def test_kernel_metric_destinations_and_an_old_route_still_active
    f = fib.merge('routes' => [
                    { 'prefix' => '2.2.2.2/32', 'state' => 'installed', 'metric' => 20, 'want' => [gw('10.0.0.2')],
                      'have' => [gw('10.0.0.2')], 'path_type' => 'intra', 'cost' => 10 },
                    { 'prefix' => '2.2.2.2/32', 'state' => 'held', 'metric' => 100, 'want' => nil, 'have' => [gw('10.0.0.2')] },
                    { 'prefix' => '3.3.3.3/32', 'state' => 'failed', 'error' => 'x', 'metric' => 20,
                      'want' => [gw('10.0.0.3')], 'have' => [gw('10.0.0.9')], 'path_type' => 'intra', 'cost' => 20 }
                  ])
    out = F.render(:fib, :junos, f)
    assert_match(/\Ainet\.0: 2 destinations, 3 routes \(3 active/, out)
    assert_match(%r{^2\.2\.2\.2/32\s+\*\[OSPF/10\], kernel metric 100$}, out)
    assert_match(%r{^3\.3\.3\.3/32\s+\*\[OSPF/10\] metric 20\n\s+>  to 10\.0\.0\.9 via eth0}, out,
                 'refused change, old route still forwarding')
    assert_match(%r{^O        2\.2\.2\.2/32 \[110/-\] via 10\.0\.0\.2, eth0, kernel metric 100$}, F.render(:fib, :ios, f))
  end
end
