# frozen_string_literal: true

require 'test/unit'
require 'support/frr_topology'
require 'support/frr_tables'

# Our router as the area border router between two FRR routers. Opt in
# with OSPFV2_FRR=1 as root with FRR installed:
#
#   sudo OSPFV2_FRR=1 ruby -Ilib -Itest test/integration/frr_abr_test.rb
#
#   r1 (FRR, area 0) --LAN, area 0-- r2 (core, ABR) --p2p, area 1-- r3 (FRR, area 1, ASBR)
#                                                                    192.0.2.0/24 E2 20
#
# FRR on each side must learn the other area from our summaries, with the
# costs RFC 2328 gives, and reach r3's external through our type 4
# summary. Our SPF rooted at each FRR router, over the database we hold
# for its area, must give that router's own table. Traffic between r1 and
# r3 crosses our router on the routes we put in its kernel.
class TestFrrAbr < Test::Unit::TestCase
  include OSPFv2::Core

  EXT = ['route-map EXT permit 10', ' match interface ext1', ' set metric 20'].freeze

  def setup
    ok, why = FrrLab.available?
    omit(why) unless ok
    @t = FrrTopology.new("abr#{Process.pid % 1000}")
    @t.frr('r1', '1.1.1.1')
    @t.core('r2', '2.2.2.2', fib: true)
    @t.frr('r3', '3.3.3.3', loopback_area: 1, frr_extra: EXT, extra: ['redistribute connected route-map EXT'],
                            dummies: { 'ext1' => '192.0.2.1/24' })
    @t.link('r1', 'r2', '10.0.12.0/24')
    @t.link('r2', 'r3', '10.0.23.0/30', p2p: true, area: 1)
    @t.start
  end

  def teardown
    @t&.stop
  end

  def table(name) = FrrTables.frr_table(@t, name)

  def agree?(name)
    FrrTables.frr_table(@t, name) == FrrTables.ours(FrrTables.rerooted(@t, 'r2', name))
  end

  def ping(from, src, dest)
    @t.run_in(from, 'ping', '-c', '1', '-W', '1', '-I', src, dest).last
  end

  def test_frr_routes_across_our_abr
    ok = @t.wait_for(120) do
      table('r1')[0].key?('192.0.2.0/24') && table('r3')[0].key?('1.1.1.1/32') && agree?('r1') && agree?('r3')
    end
    assert ok, "r1:\n#{FrrTables.pp_table(table('r1'))}\nours as r1:\n" \
               "#{FrrTables.pp_table(FrrTables.ours(FrrTables.rerooted(@t, 'r2', 'r1')))}\n" \
               "r3:\n#{FrrTables.pp_table(table('r3'))}\nours as r3:\n" \
               "#{FrrTables.pp_table(FrrTables.ours(FrrTables.rerooted(@t, 'r2', 'r3')))}\n" \
               "#{@t.core_log('r2').lines.last(20).join}"

    nets1, routers1 = table('r1')
    via_r2 = [['r2a', '10.0.12.2']]
    assert_equal ['inter', 20, nil, via_r2], nets1['3.3.3.3/32'], 'LAN 10 + p2p 10 + FRR loopback 0'
    assert_equal ['inter', 20, nil, via_r2], nets1['10.0.23.0/30']
    assert_equal ['ext2', 20, 20, via_r2], nets1['192.0.2.0/24'], 'through our type 4 summary for r3'
    assert_equal 'intra', routers1['2.2.2.2'][0]
    assert_match(/2\.2\.2\.2\s+\[10\] area: 0\.0\.0\.0, ABR/, @t.vtysh('r1', 'show ip ospf route'))
    assert_equal 'inter', routers1['3.3.3.3'][0], 'the ASBR, behind us'

    nets3, = table('r3')
    via_r2 = [['r2a', '10.0.23.1']]
    assert_equal ['inter', 20, nil, via_r2], nets3['1.1.1.1/32']
    assert_equal ['inter', 20, nil, via_r2], nets3['10.0.12.0/24']
    assert_equal ['inter', 20, nil, via_r2], nets3['2.2.2.2/32'], 'our loopback is in area 0'

    assert @t.wait_for(20) { ping('r1', '1.1.1.1', '3.3.3.3') }, 'r1 to r3 through ospfd'
    assert ping('r1', '1.1.1.1', '192.0.2.1'), 'r1 to the external network'

    # r3 goes away: the summaries for what it advertised are withdrawn.
    # (Our side of the link stays up as far as OSPF knows, so its subnet
    # is still summarized; leaving an area is covered by the unit tests.)
    @t.run_in('r2', 'ip', 'link', 'set', 'r3a', 'down')
    assert @t.wait_for(60) { !table('r1')[0].key?('3.3.3.3/32') && !table('r1')[0].key?('192.0.2.0/24') },
           FrrTables.pp_table(table('r1'))
    assert table('r1')[0].key?('10.0.23.0/30')
  end
end
