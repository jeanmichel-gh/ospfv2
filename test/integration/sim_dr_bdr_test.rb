# frozen_string_literal: true

require 'test/unit'
require 'stringio'
require 'timeout'
require 'ospfv2'
require 'ospfv2/core'

# The simulator on a broadcast segment with a DR and a BDR: RFC 2328 10.4,
# "all routers become adjacent to both the Designated Router and the
# Backup Designated Router". docs/design/sim-dr-bdr.md. The other routers
# are the core router (ospfd's), on an in-memory segment in real time.
class TestSimDrBdr < Test::Unit::TestCase
  include OSPFv2

  SIM = '10.0.0.1'

  def setup
    LSDB::Link.reset
    @hub = Transport::Hub.new
    @sim_log = StringIO.new
    @core_log = []
    @cores = {}
    @seen = [] # [from, dest, packet type] of every packet on the segment
    @drop = nil
    @hub.drop_if do |bytes, from, dest|
      type = bytes.getbyte(1)
      @seen << [from, dest, type]
      @drop ? @drop.call(from, dest, type) : false
    end
    @loop = EventLoop.new(on_error: ->(e) { @core_log << "ERROR #{e.class}: #{e.message}" }).start
  end

  def teardown
    @sim&.stop
    @loop.call { @cores.each_value(&:stop) }
    @loop.stop
  end

  def grid(cols, rows)
    db = LSDB::LinkStateDatabase.create(columns: cols, rows: rows, base_router_id: 0, base_prefix: '13.0.0.0/30')
    LSDB::Link.all.each_value { |l| db.link(l, :up) }
    db
  end

  def start_sim(db)
    @sim = Neighbor.new(router_id: '0.0.0.1', src_addr: "#{SIM}/24", hello_interval: 1,
                        transport: Transport::Loopback.new(@hub, SIM), log: @sim_log)
    @sim.ls_db = db
    @sim.start
  end

  # A core router at 10.0.0.N, router id N.N.N.N.
  def start_core(n, priority)
    addr = "10.0.0.#{n}"
    core = Core::Instance.new(router_id: ([n] * 4).join('.'), loop: @loop,
                              logger: ->(_level, msg) { @core_log << "#{n}: #{msg}" })
    @loop.call do
      core.add_interface(name: 'eth0', address: "#{addr}/24", type: :broadcast, hello_interval: 1,
                         priority: priority, transport: Transport::Loopback.new(@hub, addr))
      core.start
    end
    @cores[n] = core
  end

  def wait_for(timeout = 40, what = nil)
    Timeout.timeout(timeout) { sleep 0.05 until yield }
  rescue Timeout::Error
    flunk "timed out#{what ? " waiting for #{what}" : ''}\ncore:\n#{@core_log.last(30).join("\n")}\n" \
          "sim:\n#{@sim_log.string[-4000..]}"
  end

  # What core router n says of the simulator: :full, :two_way, ...
  def core_sees_sim(n)
    @loop.call { @cores[n].neighbors.find { |x| x.router_id == 1 }&.state }
  end

  def core_role(n)
    @loop.call { @cores[n].interfaces['eth0'].state }
  end

  def core_keys(n)
    @loop.call { @cores[n].database.map { |_, l| l.key } }
  end

  def sim_rows
    @sim.synchronize { @sim.neighbors }
  end

  def assert_no_core_errors
    assert @core_log.none? { |l| l.include?('ERROR') }, @core_log.grep(/ERROR/).join("\n")
  end

  def test_adjacent_to_both_the_dr_and_the_bdr
    db = grid(3, 3)
    expected = db.all.map(&:key)
    start_sim(db)
    start_core(9, 2)
    start_core(8, 1)
    wait_for(40, 'DR and BDR') { core_role(9) == :dr && core_role(8) == :backup }
    wait_for(40, 'both cores Full with the sim') { core_sees_sim(9) == :full && core_sees_sim(8) == :full }
    [9, 8].each { |n| wait_for(20, "core #{n} LSDB") { (expected - core_keys(n)).empty? } }
    assert @sim.full?, 'the adjacency with the DR'
    assert_equal '10.0.0.9', @sim.neighbor_ip
    # The core can say Full a moment before we do: our last request is
    # answered after its side is done.
    wait_for(15, 'the sim Full with both') { sim_rows.count { |r| r[:state] == :full } == 2 }
    rows = sim_rows.to_h { |r| [r[:address], r] }
    assert_equal({ role: 'DR', state: :full }, rows['10.0.0.9'].slice(:role, :state))
    assert_equal({ role: 'BDR', state: :full }, rows['10.0.0.8'].slice(:role, :state))
    assert_equal '10.0.0.8', @sim.hello.backup_designated_router_id.to_ip, 'our hello names the BDR'
    assert_no_core_errors
  end

  # Two exchanges at once, each over several DD packets: the paging cursor
  # must be each adjacency's own.
  def test_two_large_exchanges_at_once
    db = grid(12, 12)
    expected = db.all.map(&:key)
    assert_operator expected.size, :>, 2 * 60, 'more LSAs than two DD packets hold'
    start_core(9, 2)
    start_core(8, 1)
    wait_for(40, 'DR and BDR') { core_role(9) == :dr && core_role(8) == :backup }
    start_sim(db)
    wait_for(60, 'both cores Full with the sim') { core_sees_sim(9) == :full && core_sees_sim(8) == :full }
    [9, 8].each { |n| wait_for(30, "core #{n} LSDB") { (expected - core_keys(n)).empty? } }
    # Both from our side too: a core can say Full for an adjacency we have
    # dropped, since nothing tells it otherwise (measured on the VM).
    wait_for(10, 'the sim Full with both') do
      sim_rows.select { |r| %w[DR BDR].include?(r[:role]) }.map { |r| r[:state] } == %i[full full]
    end
    assert_no_core_errors
  end

  # An ack the BDR sends is lost: the simulator sends the LSA again to the
  # BDR, by unicast (RFC 2328 13.6), and not to the DR, which acked it.
  def test_retransmits_to_the_neighbor_that_did_not_ack
    db = grid(2, 2)
    start_sim(db)
    start_core(9, 2)
    start_core(8, 1)
    wait_for(40, 'both cores Full with the sim') { core_sees_sim(9) == :full && core_sees_sim(8) == :full }
    sleep 6 # let the first flood and its acks settle
    ack = 5
    lsu = 4
    @drop = ->(from, dest, type) { from == '10.0.0.8' && type == ack }
    @seen.clear
    @sim.synchronize do
      lsas = db.link(LSDB::Link.all.values.first, :down)
      lsas.each { |l| l.force_refresh(nil) }
      @sim.flood(lsas)
    end
    wait_for(15, 'a retransmission to the BDR') { @seen.any? { |f, d, t| f == SIM && d == '10.0.0.8' && t == lsu } }
    assert @seen.none? { |f, d, t| f == SIM && d == '10.0.0.9' && t == lsu }, 'the DR acked: nothing resent to it'
    @drop = nil
    sleep 7 # one retransmit interval: the BDR's ack gets through
    @seen.clear
    sleep 7
    assert @seen.none? { |f, d, t| f == SIM && t == lsu && d != '224.0.0.6' && d != '224.0.0.5' }, 'retransmission stopped'
  end

  # The DR stops. The BDR becomes DR and keeps its adjacency with us; the
  # router elected BDR next gets one.
  def test_bdr_takes_over_when_the_dr_stops
    db = grid(3, 3)
    start_sim(db)
    start_core(9, 2)
    start_core(8, 1)
    start_core(7, 1)
    wait_for(40, 'roles') { core_role(9) == :dr && core_role(8) == :backup && core_role(7) == :dr_other }
    wait_for(40, 'Full with DR and BDR') { core_sees_sim(9) == :full && core_sees_sim(8) == :full }
    assert_equal :two_way, core_sees_sim(7)
    wait_for(15, 'the sim Full with both') { sim_rows.count { |r| r[:state] == :full } == 2 }

    changes = []
    @sim.on_adjacency_change { |nbr, old, new, _why| changes << [nbr.neighbor_ip, old, new] }
    @loop.call { @cores.delete(9).stop }
    wait_for(40, 'new roles') { core_role(8) == :dr && core_role(7) == :backup }
    wait_for(40, 'Full with the new BDR') { core_sees_sim(7) == :full }
    assert_equal :full, core_sees_sim(8)
    assert changes.none? { |ip, _old, _new| ip == '10.0.0.8' }, "the adjacency with 10.0.0.8 stayed up: #{changes}\n#{@sim_log.string[-6000..]}"
    assert_equal '10.0.0.8', @sim.neighbor_ip
    assert_equal '10.0.0.8', @sim.hello.designated_router_id.to_ip
    assert_no_core_errors
  end

  # A router that is neither DR nor BDR stays at 2-Way: we list it in our
  # hellos and send it no DD packet.
  def test_a_drother_stays_two_way
    db = grid(2, 2)
    start_sim(db)
    start_core(9, 2)
    start_core(8, 1)
    start_core(7, 0)
    wait_for(40, 'Full with DR and BDR') { core_sees_sim(9) == :full && core_sees_sim(8) == :full }
    sleep 3
    assert_equal :two_way, core_sees_sim(7)
    dd = 2
    assert @seen.none? { |f, d, t| f == SIM && d == '10.0.0.7' && t == dd }, 'no DD to the DROther'
    assert @sim.hello.has_neighbor?(0x07070707)
    row = sim_rows.find { |r| r[:address] == '10.0.0.7' }
    assert_equal({ role: 'DROther', state: :two_way }, row.slice(:role, :state))
  end
end
