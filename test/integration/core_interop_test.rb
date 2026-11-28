# frozen_string_literal: true

require 'test/unit'
require 'stringio'
require 'timeout'
require 'ospfv2'
require 'ospfv2/core'
require 'ospfv2/simulator'

# The new router core against the old simulator: two implementations
# written years apart, talking over an in-memory segment in real time.
class TestCoreInterop < Test::Unit::TestCase
  include OSPFv2

  def setup
    LSDB::Link.reset
    @hub = Transport::Hub.new
    @sim_log = StringIO.new
    @core_log = []
    @loop = EventLoop.new(on_error: ->(e) { @core_log << "ERROR #{e.class}: #{e.message}" }).start
  end

  def teardown
    @sim&.stop
    @loop.call { @core&.stop }
    @loop.stop
  end

  def grid(cols, rows)
    db = LSDB::LinkStateDatabase.create(columns: cols, rows: rows, base_router_id: 0, base_prefix: '13.0.0.0/30')
    LSDB::Link.all.each_value { |l| db.link(l, :up) }
    db
  end

  def start_sim(network_type, db)
    @sim = Neighbor.new(router_id: '0.0.0.1', src_addr: '10.0.0.1/24', hello_interval: 1,
                        network_type: network_type, transport: Transport::Loopback.new(@hub, '10.0.0.1'),
                        log: @sim_log)
    @sim.ls_db = db
    @sim.start
  end

  def start_core(type)
    @core = Core::Instance.new(router_id: '9.9.9.9', loop: @loop,
                               logger: ->(_level, msg) { @core_log << msg })
    @loop.call do
      @core.add_interface(name: 'eth0', address: '10.0.0.9/24', type: type, hello_interval: 1,
                          transport: Transport::Loopback.new(@hub, '10.0.0.9'))
      @core.start
    end
  end

  def wait_for(timeout = 30)
    Timeout.timeout(timeout) { sleep 0.05 until yield }
  rescue Timeout::Error
    flunk "timed out\ncore:\n#{@core_log.last(30).join("\n")}\nsim:\n#{@sim_log.string[-3000..]}"
  end

  def core_keys
    @loop.call { @core.database.map { |_, l| l.key } }
  end

  def sim_keys
    @sim.synchronize { @sim.ls_db.all.map(&:key) }
  end

  def core_neighbor_state
    @loop.call { @core.neighbors.first&.state }
  end

  # The step 5 gate (docs/design/sr-ospf.md), with ospfd in FRR's place:
  # ospfd beside the simulator labels every grid SID through it, in the
  # simulator's SRGB, since the grid's routers, not the simulator, own
  # the SIDs.
  def test_sr_grid_labelled_through_the_simulator
    t = Topology.from_hash('simulator' => { 'router_id' => '1.1.1.1', 'interface' => '10.0.0.1/24', 'hello_interval' => 1 },
                           'segment_routing' => {}, 'grid' => { 'columns' => 3, 'rows' => 2, 'sids' => 1 })
    @sim = Simulator.new(t, transport: Transport::Loopback.new(@hub, '10.0.0.1'), log: @sim_log, min_ls_interval: 0)
    @sim.start
    start_core(:broadcast)
    @loop.call do
      @core.opaque = true
      @core.segment_routing = { srgb: [17_000, 8_000], srlb: [15_000, 1_000], index: nil }
    end
    want = (1..6).to_h { |i| [17_000 + i, 16_000 + i] }
    wait_for(60) do
      @loop.call do
        e = @core.sr_labels&.entries || {}
        want.all? { |in_label, out| e[in_label]&.next_hops&.map { _1[:out_label] } == [out] }
      end
    end
    @loop.call do
      sr = @core.router_information(0)
      assert_equal [[16_000, 8_000]], sr.dig('1.1.1.1', :srgb), "the simulator's own RI"
      assert_equal 8, sr.size, 'six grid routers, the simulator and ospfd itself'
    end
  end

  def test_broadcast_core_is_dr_and_learns_the_simulated_area
    db = grid(3, 3)
    expected = db.all.map(&:key)
    start_sim(:broadcast, db) # priority 0: never DR
    start_core(:broadcast)
    wait_for { @sim.full? && core_neighbor_state == :full }
    wait_for { (expected - core_keys).empty? }
    assert_equal :dr, @loop.call { @core.interfaces['eth0'].state }

    # The simulator holds our router-LSA and the network-LSA we originate as DR.
    wait_for { [[1, 0x09090909, 0x09090909], [2, 0x0a000009, 0x09090909]].all? { |k| sim_keys.include?(k) } }
    assert @core_log.none? { |l| l.start_with?('ERROR') }, @core_log.grep(/ERROR/).join("\n")
  end

  def test_point_to_point
    db = grid(4, 4)
    expected = db.all.map(&:key)
    start_sim(:p2p, db)
    start_core(:p2p)
    wait_for { @sim.full? && core_neighbor_state == :full }
    wait_for { (expected - core_keys).empty? }
    wait_for { sim_keys.include?([1, 0x09090909, 0x09090909]) }
    assert @core_log.none? { |l| l.start_with?('ERROR') }, @core_log.grep(/ERROR/).join("\n")
  end

  def test_simulator_link_change_reaches_the_core
    db = grid(2, 2)
    start_sim(:p2p, db)
    start_core(:p2p)
    wait_for { @sim.full? && core_neighbor_state == :full }
    wait_for { (db.all.map(&:key) - core_keys).empty? }
    seqs = -> { @loop.call { @core.database.to_h { |_, l| [l.key, l.seq] } } }
    before = seqs.call

    changed = @sim.synchronize do
      lsas = db.link(LSDB::Link.all.values.first, :down)
      lsas.each { |l| l.force_refresh(nil) } # as Simulator#reoriginate does
      @sim.flood(lsas)
      lsas.map(&:key)
    end
    assert_equal 2, changed.size
    wait_for(15) { changed.all? { |k| seqs.call[k] > before[k] } }
  end
end
