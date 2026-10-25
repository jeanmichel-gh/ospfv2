require 'test/unit'
require 'stringio'
require 'ospfv2/simulator'
require_relative '../../support/capture_transport'

class TestSimulator < Test::Unit::TestCase
  include OSPFv2

  def topo(**opts)
    Topology.build do
      simulator({ router_id: '1.1.1.1', interface: '192.168.1.1/24', hello_interval: 60 }.merge(opts))
      grid columns: 2, rows: 2, metric: 10
      router 'edge', id: '10.0.0.1' do
        loopback '10.255.0.1'
        summaries '30.0.0.0/24', count: 3, metric: 15
        externals '50.0.0.0/24', count: 2, metric: 20, type: 1, tag: 7
      end
      link 'r2c2', 'edge', metric: 5
    end
  end

  def setup
    @t = CaptureTransport.new('192.168.1.1')
    @sim = Simulator.new(topo, transport: @t)
  end

  def teardown
    @sim.stop if @sim.running?
  end

  def rlsa(id) = @sim.ls_db.find_router_lsa(id)

  def p2p_links(lsa) = lsa.links.select { |l| l.router_link_type.to_i == 1 }

  def test_lsdb_contents
    c = @sim.snapshot[:counts]
    assert_equal 6, c[:router]   # sim + 4 grid + edge
    assert_equal 3, c[:summary]
    assert_equal 2, c[:as_external]
    edge = rlsa('10.0.0.1')
    assert edge.abr? && edge.asbr?
    assert edge.has_link?(3, '10.255.0.1')
    ext = @sim.ls_db.lookup(:as_external, '50.0.1.0', '10.0.0.1')
    assert_match(/E1 .*Metric: 20.*Tag: 7/, ext.to_s_junos_verbose)
    assert_equal [0, 0], @sim.ls_db.all.map { |l| l.send(:cheksum, l.encode[2..], 0) }.uniq.flatten
  end

  def test_link_metrics_follow_topology
    m = p2p_links(rlsa('0.2.0.2')).find { |l| l.link_id.to_ip == '10.0.0.1' }
    assert_equal 5, m.metric.to_i
    assert p2p_links(rlsa('0.1.0.1')).all? { |l| [10].include?(l.metric.to_i) }
  end

  def test_sim_router_starts_with_interface_stub
    sim = rlsa('1.1.1.1')
    assert sim.has_link?(3, '192.168.1.0')
    assert sim.has_link?(1, '0.1.0.1'), 'attached to r1c1'
  end

  def test_link_down_and_up
    link = @sim.link('r1c1--r1c2')
    seq_before = rlsa('0.1.0.1').sequence_number.to_I
    @sim.link_down(link)
    refute link.up?
    refute rlsa('0.1.0.1').has_link?(1, '0.1.0.2')
    refute rlsa('0.1.0.2').has_link?(1, '0.1.0.1')
    assert rlsa('0.1.0.1').has_link?(3, link.lsdb_link.network.to_s), 'the stub stays'
    assert_equal seq_before + 1, rlsa('0.1.0.1').sequence_number.to_I
    @sim.link_up(link.id)
    assert rlsa('0.1.0.1').has_link?(1, '0.1.0.2')
    assert_equal seq_before + 2, rlsa('0.1.0.1').sequence_number.to_I
    assert_equal 2, @sim.events.count { |e| e.kind == :lsdb }
  end

  def test_link_down_is_idempotent
    @sim.link_down(1)
    seq = rlsa('0.1.0.1').sequence_number.to_I
    @sim.link_down(1)
    assert_equal seq, rlsa('0.1.0.1').sequence_number.to_I
  end

  def test_unknown_link
    e = assert_raise(ArgumentError) { @sim.link_down('nope') }
    assert_match(/no such link/, e.message)
  end

  def test_initially_down_link
    t = Topology.from_hash(grid: { columns: 2, rows: 1 }, links: [{ from: 'r1c1', to: 'sim' }, { from: 'r1c2', to: 'sim', state: 'down' }])
    sim = Simulator.new(t, transport: CaptureTransport.new)
    refute sim.ls_db.find_router_lsa('1.1.1.1').has_link?(1, '0.1.0.2')
    assert sim.ls_db.find_router_lsa('1.1.1.1').has_link?(1, '0.1.0.1')
  end

  def test_full_with_dr_advertises_transit_link
    @sim.start
    @sim.neighbor.hello.designated_router_id = '192.168.1.254'
    @sim.synchronize { @sim.neighbor.change_state(NeighborState::Full.new, 'test') }
    sim = rlsa('1.1.1.1')
    assert sim.has_link?(2, '192.168.1.254'), 'transit link to the DR'
    refute sim.has_link?(3, '192.168.1.0'), 'no stub once the transit link is up'
    @sim.synchronize { @sim.neighbor.change_state(NeighborState::Down.new, 'test') }
    assert sim.has_link?(3, '192.168.1.0'), 'back to a stub when the adjacency drops'
    refute sim.has_link?(2, '192.168.1.254')
  end

  def test_intermediate_states_do_not_reoriginate
    @sim.start
    seq = rlsa('1.1.1.1').sequence_number.to_I
    %w[Init ExStart Exchange Loading].each do |st|
      klass = NeighborState.const_get(st)
      state = klass.instance_method(:initialize).arity.zero? ? klass.new : klass.allocate
      @sim.synchronize { @sim.neighbor.change_state(state, 'test') }
    end
    assert_equal seq, rlsa('1.1.1.1').sequence_number.to_I
  end

  def test_full_on_p2p_advertises_p2p_link
    sim = Simulator.new(topo(network_type: 'p2p'), transport: CaptureTransport.new)
    sim.start
    sim.neighbor.instance_variable_set(:@neighbor_router_id, Neighbor::RouterId.new('2.2.2.2'))
    sim.synchronize { sim.neighbor.change_state(NeighborState::Full.new, 'test') }
    l = sim.ls_db.find_router_lsa('1.1.1.1')
    assert l.has_link?(1, '2.2.2.2')
    assert l.has_link?(3, '192.168.1.0')
  ensure
    sim&.stop
  end

  def test_changes_are_flooded_when_full
    @sim.start
    @sim.synchronize { @sim.neighbor.change_state(NeighborState::Full.new, 'test') }
    @t.sent.clear
    @sim.link_down('r1c1--r2c1')
    lsu = @t.packets(LinkStateUpdate)
    assert_equal 1, lsu.size
    assert_equal %w[0.1.0.1 0.2.0.1], lsu.first.lsas.map { |l| l.advertising_router.to_ip }.sort
    assert_equal '224.0.0.6', @t.sent.last.last
  end

  def test_refresh_and_flush
    n = @sim.ls_db.all_proxied.size
    assert_equal n, @sim.refresh_all.size
    assert @sim.ls_db.all.all? { |l| l.sequence_number.to_I == 0x80000002 }
    @sim.flush_all
    assert @sim.ls_db.all_proxied.all?(&:maxaged?)
  end

  def test_flap
    sim = @sim
    states = []
    sim.flap(1, count: 2, interval: 0.05)
    10.times { states << sim.link(1).up?; sleep 0.03 }
    sleep 0.3
    assert_include states, false
    assert sim.link(1).up?
    assert_equal 4, sim.events.count { |e| e.text.start_with?('link r1c1--r1c2') }
  end

  def test_snapshot_and_rows_are_json_ready
    require 'json'
    JSON.generate(@sim.snapshot)
    rows = @sim.lsdb_rows
    assert_equal @sim.ls_db.size, rows.size
    assert rows.all? { |r| r[:originated] }
    g = @sim.graph
    assert_include g[:nodes].map { |n| n[:id] }, 'dut'
  end

  def test_lsdb_text_formats
    assert_match(/OSPF link state database/, @sim.lsdb_text(:junos))
    assert_match(/Extern\s+50.0.0.0/, @sim.lsdb_text(:junos))
    assert_match(/Router Link States|Router Links/, @sim.lsdb_text(:ios))
  end
end
