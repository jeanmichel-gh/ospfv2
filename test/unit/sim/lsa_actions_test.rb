require 'test/unit'
require 'ipaddr'
require 'ospfv2/simulator'
require_relative '../../support/capture_transport'

# One LSA refreshed or flushed, the topology's routes withdrawn and
# advertised, and MinLSInterval (docs/design/sim-lsa-actions.md).
class TestSimulatorLsaActions < Test::Unit::TestCase
  include OSPFv2

  # Short enough that the suite does not sleep long, long enough that two
  # calls in a row fall inside it.
  INTERVAL = 0.4

  def topo
    Topology.build do
      simulator router_id: '1.1.1.1', interface: '192.168.1.1/24', hello_interval: 60
      grid columns: 2, rows: 2, metric: 10
      router 'edge', id: '10.0.0.1' do
        summaries '30.0.0.0/24', count: 2, metric: 15
        externals '50.0.0.0/24', count: 2, metric: 20
      end
      link 'r2c2', 'edge', metric: 5
    end
  end

  def sim(interval = 0)
    @sim = Simulator.new(topo, transport: CaptureTransport.new('192.168.1.1'), min_ls_interval: interval)
  end

  def teardown
    @sim&.stop
  end

  def seq(type, id, advr) = @sim.ls_db.lookup(type, id, advr).sequence_number.to_I
  def ext = @sim.ls_db.lookup(:as_external, '50.0.1.0', '10.0.0.1')

  # ---- one LSA

  def test_refresh_one_lsa_moves_only_it
    sim
    others = @sim.ls_db.all.to_h { [_1.key, _1.sequence_number.to_I] }
    before = seq(:router, '0.1.0.1', '0.1.0.1')
    row = @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1')
    assert_equal format('0x%08x', before + 1), row[:seq]
    changed = @sim.ls_db.all.select { others[_1.key] && others[_1.key] != _1.sequence_number.to_I }
    assert_equal [[1, IPAddr.new('0.1.0.1').to_i, IPAddr.new('0.1.0.1').to_i]], changed.map(&:key)
    e = @sim.events.last
    assert_match(/refresh of router 0.1.0.1 from 0.1.0.1: re-originated 1 LSA/, e.text)
    assert_equal [{ type: :router, id: '0.1.0.1', advr: '0.1.0.1', seq: row[:seq] }], e.data[:lsas]
  end

  def test_flush_keeps_the_sequence_number_and_refresh_brings_it_back
    sim
    before = seq(:router, '0.1.0.1', '0.1.0.1')
    row = @sim.lsa_flush('router', '0.1.0.1', '0.1.0.1')
    assert_equal [format('0x%08x', before), 3600, true], row.values_at(:seq, :age, :flushed)
    # The router acks the MaxAge copy and both drop it.
    @sim.ls_db.ls_ack(@sim.ls_db.lookup(:router, '0.1.0.1', '0.1.0.1'))
    assert_nil @sim.ls_db.lookup(:router, '0.1.0.1', '0.1.0.1')
    # A link change meanwhile skips the missing LSA; it comes back with it.
    @sim.link_down('r1c1--r1c2')
    row = @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1')
    assert_equal [format('0x%08x', before + 1), 0], row.values_at(:seq, :age)
    refute row.key?(:flushed)
    refute @sim.ls_db.find_router_lsa('0.1.0.1').has_link?(1, '0.1.0.2'), 'the link went down while it was flushed'
    assert @sim.ls_db.find_router_lsa('0.1.0.1').has_link?(1, '0.2.0.1')
  end

  def test_flush_twice_answers_the_flushed_copy
    sim
    a = @sim.lsa_flush('router', '0.1.0.1', '0.1.0.1')
    assert_equal a[:seq], @sim.lsa_flush('router', '0.1.0.1', '0.1.0.1')[:seq]
  end

  def test_an_lsa_it_does_not_originate_is_refused
    sim
    @sim.ls_db << Router.new(advertising_router: '9.9.9.9', ls_id: '9.9.9.9')
    %i[lsa_refresh lsa_flush].each do |m|
      e = assert_raise(PermissionError) { @sim.public_send(m, 'router', '9.9.9.9', '9.9.9.9') }
      assert_match(/not originated by the simulator \(RFC 2328 14.1\)/, e.message)
    end
  end

  def test_its_own_router_lsa_refreshes_but_does_not_flush
    sim
    before = seq(:router, '1.1.1.1', '1.1.1.1')
    @sim.lsa_refresh('router', '1.1.1.1', '1.1.1.1')
    assert_equal before + 1, seq(:router, '1.1.1.1', '1.1.1.1')
    e = assert_raise(PermissionError) { @sim.lsa_flush('router', '1.1.1.1', '1.1.1.1') }
    assert_match(/stop the neighbor instead/, e.message)
  end

  def test_unknown_and_bad_lsas
    sim
    assert_raise(Simulator::NotFound) { @sim.lsa_refresh('router', '9.9.9.9', '9.9.9.9') }
    assert_raise_message(/type "bogus"/) { @sim.lsa_refresh('bogus', '0.1.0.1', '0.1.0.1') }
    assert_raise_message(/required/) { @sim.lsa_flush('router', '', '') }
    assert_raise(ArgumentError) { @sim.lsa_flush('router', 'x.y', 'x.y') }
  end

  def test_refresh_all_brings_back_one_flushed
    sim
    @sim.lsa_flush('as_external', '50.0.1.0', '10.0.0.1')
    @sim.refresh_all
    assert_equal 0, ext.ls_age.to_i
    refute @sim.lsa_row(ext).key?(:flushed)
  end

  # ---- routes

  def test_withdraw_and_advertise_an_external
    sim
    before = ext.sequence_number.to_I
    row = @sim.routes_withdraw('edge', '50.0.1.0/24')
    assert_equal [:as_external, 'edge', '50.0.1.0/24', 3600, format('0x%08x', before)],
                 row.values_at(:kind, :router, :prefix, :age, :seq)
    assert @sim.routes_withdraw('edge', '50.0.1.0/24')[:already]
    row = @sim.routes_advertise('edge', '50.0.1.0/24')
    assert_equal [0, format('0x%08x', before + 1)], row.values_at(:age, :seq)
    assert @sim.routes_advertise('edge', '50.0.1.0/24')[:already]
  end

  def test_withdraw_a_summary
    sim
    row = @sim.routes_withdraw('edge', '30.0.1.0/24')
    assert_equal [:summary, 3600], row.values_at(:kind, :age)
    assert_equal 3600, @sim.ls_db.lookup(:summary, '30.0.1.0', '10.0.0.1').ls_age.to_i
  end

  def test_routes_not_in_the_topology
    sim
    assert_raise_message(/no router "nope"/) { @sim.routes_withdraw('nope', '50.0.0.0/24') }
    e = assert_raise(Simulator::NotFound) { @sim.routes_withdraw('edge', '203.0.113.0/24') }
    assert_match(/edge has no external or summary 203.0.113.0\/24 \(50.0.0.0\/24/, e.message)
    assert_raise(Simulator::NotFound) { @sim.routes_withdraw('edge', '50.0.1.0/25') }
    assert_raise(ArgumentError) { @sim.routes_withdraw('edge', 'not a prefix') }
  end

  # ---- MinLSInterval

  def test_a_second_refresh_inside_the_interval_is_held_and_goes_out_once
    sim(INTERVAL)
    before = seq(:router, '0.1.0.1', '0.1.0.1')
    @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1')
    row = @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1')
    @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1')
    assert row[:deferred_ms].between?(1, INTERVAL * 1000)
    assert_equal before + 1, seq(:router, '0.1.0.1', '0.1.0.1'), 'held'
    assert_equal 1, @sim.snapshot[:counts][:deferred]
    sleep INTERVAL + 0.2
    assert_equal before + 2, seq(:router, '0.1.0.1', '0.1.0.1'), 'one instance for the two held refreshes'
    refute @sim.lsa_row(@sim.ls_db.find_router_lsa('0.1.0.1')).key?(:deferred_ms)
    assert_match(/re-originated 1 LSA after MinLSInterval/, @sim.events.last.text)
  end

  def test_two_metric_changes_inside_the_interval_send_one_instance_with_the_second
    sim(INTERVAL)
    before = seq(:router, '0.1.0.1', '0.1.0.1')
    @sim.set_metric('r1c1--r1c2', 25)
    @sim.set_metric('r1c1--r1c2', 30)
    assert_equal before + 1, seq(:router, '0.1.0.1', '0.1.0.1')
    sleep INTERVAL + 0.2
    assert_equal before + 2, seq(:router, '0.1.0.1', '0.1.0.1')
    link = @sim.ls_db.find_router_lsa('0.1.0.1').links.find { _1.router_link_type.to_i == 1 && _1.link_id.to_ip == '0.1.0.2' }
    assert_equal 30, link.metric.to_i
  end

  def test_an_advertise_right_after_a_withdraw_waits
    sim(INTERVAL)
    @sim.routes_withdraw('edge', '50.0.1.0/24')
    row = @sim.routes_advertise('edge', '50.0.1.0/24')
    assert row[:deferred_ms].positive?
    assert_equal 3600, ext.ls_age.to_i, 'still flushed'
    sleep INTERVAL + 0.2
    assert_equal 0, ext.ls_age.to_i
  end

  def test_after_the_interval_it_goes_out_at_once
    sim(0.1)
    @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1')
    sleep 0.15
    refute @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1').key?(:deferred_ms)
  end

  def test_the_interval_can_be_set_from_0_to_5
    sim(INTERVAL)
    before = seq(:router, '0.1.0.1', '0.1.0.1')
    @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1')
    @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1')
    @sim.min_ls_interval = 0
    assert_equal before + 2, seq(:router, '0.1.0.1', '0.1.0.1'), 'what was held goes out at once'
    @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1')
    assert_equal before + 3, seq(:router, '0.1.0.1', '0.1.0.1'), 'and so does every change after'
    assert_equal 0.0, @sim.snapshot[:min_ls_interval]
    @sim.min_ls_interval = 2.5
    assert_equal 2.5, @sim.min_ls_interval
    assert_raise_message(/from 0 to 5/) { @sim.min_ls_interval = 6 }
    assert_raise_message(/from 0 to 5/) { @sim.min_ls_interval = -1 }
    assert_raise_message(/from 0 to 5/) { @sim.min_ls_interval = 'x' }
  end

  def test_five_seconds_by_default
    @sim = Simulator.new(topo, transport: CaptureTransport.new('192.168.1.1'))
    assert_equal 5.0, @sim.min_ls_interval
  end

  def test_a_stop_settles_what_is_held
    sim(INTERVAL)
    before = seq(:router, '0.1.0.1', '0.1.0.1')
    @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1')
    @sim.lsa_refresh('router', '0.1.0.1', '0.1.0.1')
    @sim.stop
    assert_equal before + 2, seq(:router, '0.1.0.1', '0.1.0.1')
    assert_equal 0, @sim.snapshot[:counts][:deferred]
  end
end
