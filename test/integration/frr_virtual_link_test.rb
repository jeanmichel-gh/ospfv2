# frozen_string_literal: true

require 'test/unit'
require 'support/frr_topology'
require 'support/frr_tables'

# A virtual link between FRR and our router across two hops of a transit
# area. Opt in with OSPFV2_FRR=1 as root with FRR installed:
#
#   sudo OSPFV2_FRR=1 ruby -Ilib -Itest test/integration/frr_virtual_link_test.rb
#
#   r1 (FRR, area 0) -- r2 (FRR, ABR 0/1) -- area 1 -- r5 (FRR, area 1) -- area 1 -- r3 (core, areas 1 and 2) -- r4 (FRR, area 2)
#                       \_____________ virtual link r2 <-> r3 through area 1 _____________/
#
# Area 2 has no backbone interface: it reaches the rest only over the
# virtual link, whose packets cross r5 as routed unicast.
class TestFrrVirtualLink < Test::Unit::TestCase
  include OSPFv2::Core

  def setup
    ok, why = FrrLab.available?
    omit(why) unless ok
    @t = FrrTopology.new("vl#{Process.pid % 1000}")
    @t.frr('r1', '1.1.1.1')
    @t.frr('r2', '2.2.2.2', extra: ['area 0.0.0.1 virtual-link 3.3.3.3'])
    @t.frr('r5', '5.5.5.5', loopback_area: 1)
    @t.core('r3', '3.3.3.3', loopback_area: 2, fib: true,
                             virtual_links: [{ neighbor: '2.2.2.2', transit_area: '0.0.0.1' }])
    @t.frr('r4', '4.4.4.4', loopback_area: 2)
    @t.link('r1', 'r2', '10.0.12.0/30', p2p: true)
    @t.link('r2', 'r5', '10.0.25.0/30', p2p: true, area: 1)
    @t.link('r5', 'r3', '10.0.35.0/30', p2p: true, area: 1)
    @t.link('r3', 'r4', '10.0.34.0/30', p2p: true, area: 2)
    @t.start
  end

  def teardown
    @t&.stop
  end

  def table(name) = FrrTables.frr_table(@t, name)
  def ours_as(name) = FrrTables.ours(FrrTables.rerooted(@t, 'r3', name))
  def ping(from, src, dest) = @t.run_in(from, 'ping', '-c', '1', '-W', '1', '-I', src, dest).last

  def vlink_full?
    @t.vtysh('r2', 'show ip ospf neighbor').match?(/3\.3\.3\.3\s+\S+\s+Full.*VLINK/)
  end

  def test_area_2_over_the_virtual_link
    ok = @t.wait_for(150) do
      vlink_full? && table('r1')[0].key?('4.4.4.4/32') && table('r4')[0].key?('1.1.1.1/32') && table('r1') == ours_as('r1')
    end
    assert ok, "r2 neighbors:\n#{@t.vtysh('r2', 'show ip ospf neighbor')}\nr1:\n#{FrrTables.pp_table(table('r1'))}\n" \
               "ours as r1:\n#{FrrTables.pp_table(ours_as('r1'))}\n#{@t.core_log('r3').lines.last(25).join}"
    nets1, = table('r1')
    assert_equal 'inter', nets1['4.4.4.4/32'][0]
    assert_equal 40, nets1['4.4.4.4/32'][1], 'r1-r2 10 + virtual link 20 (two hops) + r3-r4 10 + FRR loopback 0'
    assert_equal 'inter', table('r4')[0]['1.1.1.1/32'][0]
    assert_match(/Peer 10\.0\.35\.2, Area 0\.0\.0\.0.*VIRTUALLINK, Cost: 20/m, @t.vtysh('r2', 'show ip ospf interface'))
    assert @t.wait_for(20) { ping('r4', '4.4.4.4', '1.1.1.1') }, 'area 2 to the backbone'
  end
end
