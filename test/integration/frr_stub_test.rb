# frozen_string_literal: true

require 'test/unit'
require 'support/frr_topology'
require 'support/frr_tables'

# Our router as the ABR of a stub area. Opt in with OSPFV2_FRR=1 as root
# with FRR installed:
#
#   sudo OSPFV2_FRR=1 ruby -Ilib -Itest test/integration/frr_stub_test.rb
#
#   r1 (FRR, area 0, ASBR) --LAN-- r2 (core, ABR) --p2p, area 1 stub-- r3 (FRR)
#   192.0.2.0/24 E2 20
#
# r3 must form an adjacency with us (same stub flag), get our default
# route and the backbone's summaries, no externals, and reach r1's
# external network through the default.
class TestFrrStub < Test::Unit::TestCase
  EXT = ['route-map EXT permit 10', ' match interface ext1', ' set metric 20'].freeze

  def start(no_summaries: false)
    ok, why = FrrLab.available?
    omit(why) unless ok
    @t = FrrTopology.new("stub#{Process.pid % 1000}")
    @t.frr('r1', '1.1.1.1', frr_extra: EXT, extra: ['redistribute connected route-map EXT'],
                            dummies: { 'ext1' => '192.0.2.1/24' })
    @t.core('r2', '2.2.2.2', fib: true, areas: { '0.0.0.1' => { stub: { no_summaries: no_summaries } } })
    @t.frr('r3', '3.3.3.3', loopback_area: 1, extra: ['area 1 stub'])
    @t.link('r1', 'r2', '10.0.12.0/24')
    @t.link('r2', 'r3', '10.0.23.0/30', p2p: true, area: 1)
    @t.start
  end

  def teardown
    @t&.stop
  end

  def table(name) = FrrTables.frr_table(@t, name)
  def agree?(name) = table(name) == FrrTables.ours(FrrTables.rerooted(@t, 'r2', name))

  def converge(*must)
    ok = @t.wait_for(120) { must.all? { |p| table('r3')[0].key?(p) } && table('r1')[0].key?('3.3.3.3/32') && agree?('r3') }
    assert ok, "r3:\n#{FrrTables.pp_table(table('r3'))}\nours as r3:\n" \
               "#{FrrTables.pp_table(FrrTables.ours(FrrTables.rerooted(@t, 'r2', 'r3')))}\n" \
               "#{@t.core_log('r2').lines.last(20).join}"
  end

  def ping(dest) = @t.run_in('r3', 'ping', '-c', '1', '-W', '1', '-I', '3.3.3.3', dest).last

  def test_stub_area
    start
    converge('0.0.0.0/0', '1.1.1.1/32')
    nets, = table('r3')
    via_r2 = [['r2a', '10.0.23.1']]
    assert_equal ['inter', 11, nil, via_r2], nets['0.0.0.0/0'], 'default cost 1 + the link'
    assert_equal ['inter', 20, nil, via_r2], nets['1.1.1.1/32']
    assert(nets.none? { |_, (type, *)| type.start_with?('ext') }, 'no externals in a stub area')
    assert_empty @t.frr_json('r3', 'show ip ospf database external').fetch('asExternalLinkStates', [])
    assert @t.wait_for(15) { FrrTables.core_routes(@t, 'r2').key?('192.0.2.0/24') }, 'the ABR has the external'
    assert @t.wait_for(20) { ping('192.0.2.1') }, 'r3 reaches the external network through the default'
  end

  def test_totally_stubby_area
    start(no_summaries: true)
    converge('0.0.0.0/0')
    nets, = table('r3')
    assert_equal %w[0.0.0.0/0 10.0.23.0/30 3.3.3.3/32], nets.keys.sort, 'only the default comes in'
    assert @t.wait_for(20) { ping('1.1.1.1') }
  end
end
