require 'test/unit'
require 'stringio'
require 'timeout'
require 'ospfv2'

# Two Neighbors on an in-memory segment: one floods a generated LSDB,
# the other starts empty. They must reach Full and sync the database.
class TestAdjacency < Test::Unit::TestCase
  include OSPFv2

  def setup
    LSDB::Link.reset
    @hub = Transport::Hub.new
    @logs = [StringIO.new, StringIO.new]
  end

  def teardown
    [@a, @b].compact.each(&:stop)
  end

  def build(router_id, address, ls_db: nil, log: StringIO.new)
    n = Neighbor.new(router_id: router_id, src_addr: "#{address}/24", hello_interval: 1,
                     transport: Transport::Loopback.new(@hub, address), log: log)
    n.ls_db = ls_db || LSDB::LinkStateDatabase.new(area_id: 0)
    n
  end

  def wait_for(timeout = 20)
    Timeout.timeout(timeout) { sleep 0.1 until yield }
  rescue Timeout::Error
    flunk "timed out. A:\n#{@logs[0].string[-3000..]}\nB:\n#{@logs[1].string[-3000..]}"
  end

  def grid_lsdb(cols, rows)
    db = LSDB::LinkStateDatabase.create(columns: cols, rows: rows, base_router_id: 0, base_prefix: '13.0.0.0/30')
    LSDB::Link.all.each_value { |l| db.link(l, :up) }
    db
  end

  def keys(db)
    db.all.map(&:key).sort
  end

  def test_full_adjacency_and_database_sync
    db = grid_lsdb(3, 3)
    expected = keys(db)
    @a = build('0.0.0.1', '10.0.0.1', ls_db: db, log: @logs[0])
    @b = build('0.0.0.200', '10.0.0.2', log: @logs[1])
    @a.start
    @b.start
    wait_for { @a.full? && @b.full? }
    wait_for { (expected - keys(@b.ls_db)).empty? }
    assert_equal expected, keys(@b.ls_db) & expected
  end

  def test_sync_when_simulator_has_the_lower_router_id
    db = grid_lsdb(2, 2)
    expected = keys(db)
    @a = build('9.9.9.9', '10.0.0.1', ls_db: db, log: @logs[0])
    @b = build('1.1.1.1', '10.0.0.2', log: @logs[1])
    @a.start
    @b.start
    wait_for { @a.full? && @b.full? }
    wait_for { (expected - keys(@b.ls_db)).empty? }
  end

  def test_large_database_paged_over_several_dd_packets
    db = grid_lsdb(12, 12) # 144 router LSAs, more than one DD page
    expected = keys(db)
    @a = build('0.0.0.1', '10.0.0.1', ls_db: db, log: @logs[0])
    @b = build('0.0.0.200', '10.0.0.2', log: @logs[1])
    @a.start
    @b.start
    wait_for(40) { @a.full? && @b.full? && (expected - keys(@b.ls_db)).empty? }
  end

  # Drop the first DD the slave answers with, and the first LSU.
  # Retransmissions must still converge.
  def test_recovers_from_lost_dd_and_lsu
    dropped = Hash.new(0)
    @hub.drop_if do |bytes, from, _dest|
      type = bytes.getbyte(1)
      key = [from, type]
      next false unless [2, 4].include?(type) && dropped[key] < 1
      next false if type == 2 && bytes.getbyte(27).to_i & 4 == 4 # keep the initial I-bit DDs
      dropped[key] += 1
      true
    end
    db = grid_lsdb(3, 3)
    expected = keys(db)
    @a = build('0.0.0.1', '10.0.0.1', ls_db: db, log: @logs[0])
    @b = build('0.0.0.200', '10.0.0.2', log: @logs[1])
    @a.start
    @b.start
    wait_for(40) { @a.full? && @b.full? && (expected - keys(@b.ls_db)).empty? }
    assert dropped.keys.map(&:last).uniq.sort == [2, 4], "expected a DD and an LSU drop, got #{dropped.inspect}"
  end

  # On a LAN the DR refloods every update it receives, our own LSAs
  # included. Those echoes are acks: ages must keep growing and sequence
  # numbers must not move.
  def test_echoes_from_a_dr_do_not_reset_our_lsas
    db = grid_lsdb(3, 3)
    @a = build('0.0.0.1', '10.0.0.1', ls_db: db, log: @logs[0])
    @b = build('0.0.0.200', '10.0.0.2', log: @logs[1])
    def @b.recv_link_state_update(lsu, *args)
      super
      flood(lsu.lsas, AllSPFRouters)
    end
    @a.start
    @b.start
    wait_for { @a.full? && @b.full? }
    LsAge.aging :on
    sleep 3
    seqs = db.all.map { |l| l.sequence_number.to_I }.uniq
    assert_equal [0x80000001], seqs, 'echoes bumped sequence numbers'
    assert db.all.all? { |l| l.ls_age.to_i >= 2 }, 'echoes reset ages'
  ensure
    LsAge.aging :off
  end

  def test_inactivity_timer_brings_neighbor_down
    @a = build('0.0.0.1', '10.0.0.1', ls_db: grid_lsdb(2, 1), log: @logs[0])
    @b = build('0.0.0.2', '10.0.0.2', log: @logs[1])
    @a.start
    @b.start
    wait_for { @a.full? }
    @b.stop
    wait_for(10) { @a.state == :down }
  end
end
