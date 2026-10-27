# frozen_string_literal: true

require 'test/unit'
require 'support/frr_topology'
require 'support/frr_tables'

# Our router as the ABR and translator of an NSSA (RFC 3101). Opt in with
# OSPFV2_FRR=1 as root with FRR installed:
#
#   sudo OSPFV2_FRR=1 ruby -Ilib -Itest test/integration/frr_nssa_test.rb
#
#   r1 (FRR, area 0, ASBR) --LAN-- r2 (core, ABR, ASBR) --p2p, area 1 NSSA-- r3 (FRR, NSSA ASBR)
#   198.51.100.0/24 E2          203.0.113.0/24 E2 15                      192.0.2.0/24 type 7
#
# r3's type 7 route must reach r1 as a type 5 we translate, with r3's
# forwarding address; r1's type 5 must stay out of the NSSA; our own route
# must reach r3 as type 7 and r1 as type 5. Both FRR tables must match
# our SPF from their seats, and traffic must cross.
class TestFrrNssa < Test::Unit::TestCase
  include OSPFv2::Core

  EXT1 = ['route-map EXT permit 10', ' match interface ext1', ' set metric 20'].freeze

  def setup
    ok, why = FrrLab.available?
    omit(why) unless ok
    @t = FrrTopology.new("nssa#{Process.pid % 1000}")
    @t.frr('r1', '1.1.1.1', frr_extra: EXT1, extra: ['redistribute connected route-map EXT'],
                            dummies: { 'ext1' => '198.51.100.1/24' })
    @t.core('r2', '2.2.2.2', fib: true, areas: { '0.0.0.1' => { nssa: {} } },
                             dummies: { 'ext9' => '203.0.113.1/24' },
                             externals: [{ prefix: '203.0.113.0/24', metric: 15, type: 2 }])
    @t.frr('r3', '3.3.3.3', loopback_area: 1, frr_extra: EXT1, extra: ['area 1 nssa', 'redistribute connected route-map EXT'],
                            dummies: { 'ext1' => '192.0.2.1/24' })
    @t.link('r1', 'r2', '10.0.12.0/24')
    @t.link('r2', 'r3', '10.0.23.0/30', p2p: true, area: 1)
    @t.start
  end

  def teardown
    @t&.stop
  end

  def table(name) = FrrTables.frr_table(@t, name)
  def ours_as(name) = FrrTables.ours(FrrTables.rerooted(@t, 'r2', name))
  def ping(from, src, dest) = @t.run_in(from, 'ping', '-c', '1', '-W', '1', '-I', src, dest).last

  def test_nssa_through_our_abr
    ok = @t.wait_for(120) do
      table('r1')[0].key?('192.0.2.0/24') && table('r3')[0].key?('203.0.113.0/24') &&
        table('r1')[0].key?('203.0.113.0/24') && table('r1') == ours_as('r1') && table('r3') == ours_as('r3')
    end
    assert ok, "r1:\n#{FrrTables.pp_table(table('r1'))}\nours as r1:\n#{FrrTables.pp_table(ours_as('r1'))}\n" \
               "r3:\n#{FrrTables.pp_table(table('r3'))}\nours as r3:\n#{FrrTables.pp_table(ours_as('r3'))}\n" \
               "#{@t.vtysh('r3', 'show ip ospf database nssa-external')}\n#{@t.core_log('r2').lines.last(20).join}"

    text = @t.vtysh('r1', 'show ip ospf database external 192.0.2.0')
    assert_match(/Advertising Router: 2\.2\.2\.2/, text, 'we translate')
    assert_match(/Forward Address: 3\.3\.3\.3/, text, "r3's forwarding address kept")

    nets3, = table('r3')
    refute nets3.key?('198.51.100.0/24'), 'no type 5 in the NSSA'
    assert_match(/2\.2\.2\.2/, @t.vtysh('r3', 'show ip ospf database nssa-external 203.0.113.0'), 'our type 7')

    assert @t.wait_for(20) { ping('r1', '1.1.1.1', '192.0.2.1') }, 'r1 to the NSSA external'
    assert ping('r3', '3.3.3.3', '203.0.113.1'), 'r3 to our external'
  end
end
