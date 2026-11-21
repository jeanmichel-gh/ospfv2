# frozen_string_literal: true

require 'test/unit'
require 'support/core_lab'
require 'support/fake_bfd_client'

# BFD for OSPF neighbors (Core::Bfd), on a fake clock with a fake client:
# when a session is wanted and let go, what a BFD event does to the
# neighbor, and what it never does (RFC 5882 4.1, 4.2, 10.1.2).
class TestCoreBfd < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  def setup
    @lab = CoreLab.new
    @client = FakeBfdClient.new
  end

  # a runs BFD on eth0; b is the other end, BFD or not.
  def pair(bfd: {}, a_opts: {}, b_opts: {})
    lan = @lab.segment
    @a = @lab.router('1.1.1.1', [lan, '10.0.0.1/24', { bfd: bfd, **a_opts }])
    @b = @lab.router('2.2.2.2', [lan, '10.0.0.2/24', b_opts])
    @bfd = Bfd.new(@a, @client)
    @lab.start
  end

  def nbr = @lab.neighbor(@a, '2.2.2.2')

  def full!
    @lab.run_until(120) { @lab.full?(@a, @b) }
  end

  # Hands the client's events to the router as the daemon does: posted to
  # the loop, run when it drains.
  def deliver
    events = @client.take
    @lab.loop.post { @bfd.handle(events) }
    @lab.loop.drain
  end

  def neighbor_events(r = @a) = r.events.select { |e| e.kind == :neighbor }.map(&:data)

  def test_wants_the_session_at_two_way_to_the_interface_address
    pair(bfd: { minimum_interval: 100, multiplier: 4 })
    @lab.run_until(30) { nbr }
    assert_equal :init, nbr.state
    assert_empty @client.wanted, 'not wanted before 2-Way'
    full!
    assert_equal({ ['eth0', '10.0.0.2'] => { interface: 'eth0', peer: '10.0.0.2', local: '10.0.0.1',
                                             desired_min_tx: 100_000, required_min_rx: 100_000, detect_mult: 4 } },
                 @client.wanted)
    assert_equal 1, @client.calls.count { |c| c[0] == :want }, 'asked once, not at each state'
  end

  # Two DROthers stay at 2-Way: the session is wanted all the same.
  def test_wanted_at_two_way_without_an_adjacency
    pair(a_opts: { priority: 0 }, b_opts: { priority: 0 })
    @lab.run_until(120) { nbr&.state == :two_way }
    @lab.advance(60)
    assert_equal :two_way, nbr.state
    assert @client.wanted?(interface: 'eth0', peer: '10.0.0.2')
    assert_equal({ interface: 'eth0', peer: '10.0.0.2', local: '10.0.0.1' }, @client.wanted.values.first,
                 "bfdd4r's timers when none are configured")
  end

  def test_no_session_on_an_interface_without_bfd
    pair(bfd: nil)
    full!
    assert_empty @client.calls
    refute nbr.summary.key?(:bfd)
  end

  def test_let_go_when_the_neighbor_goes_down
    pair
    full!
    @b.stop
    @lab.run_until(60) { nbr.nil? }
    assert_empty @client.wanted
    assert_equal [:drop, %w[eth0 10.0.0.2]], @client.calls.last
  end

  # RFC 5882 4.1: OSPFv2 cannot say it runs BFD, so a neighbor never waits
  # for a session. Here no session ever comes up.
  def test_never_waits_for_bfd
    pair
    took = @lab.run_until(120) { @lab.full?(@a, @b) }
    assert_operator took, :<, 60
    assert_equal 'down', nbr.summary[:bfd]
  end

  def test_neighbors_table_says_up_and_down
    pair
    full!
    assert_equal 'down', nbr.summary[:bfd]
    @client.up('eth0', '10.0.0.2')
    deliver
    assert_equal 'up', nbr.summary[:bfd]
  end

  # RFC 5882 10.1.2: Up to Down tears the neighbor down.
  def test_failure_kills_the_neighbor
    pair
    full!
    @client.up('eth0', '10.0.0.2')
    deliver
    @client.failure('eth0', '10.0.0.2')
    deliver
    down = neighbor_events.find { |d| d[:to] == 'down' }
    assert_equal({ router_id: '2.2.2.2', address: '10.0.0.2', from: 'full', to: 'down', event: 'BFD down' }, down)
    bfd = @a.events.select { |e| e.kind == :bfd }.map(&:data)
    assert_include bfd, { peer: '10.0.0.2', from: 'up', to: 'down', diag: 'control_detection_time_expired' }
    assert_empty @client.wanted, 'the session goes with the neighbor'
  end

  # A session that never came Up going Down is no failure.
  def test_down_without_up_does_nothing
    pair
    full!
    @client.state('eth0', '10.0.0.2', :init)
    @client.state('eth0', '10.0.0.2', :down)
    deliver
    assert nbr.full?
  end

  # RFC 5882 4.2: the peer AdminDown, or ours, takes no action.
  def test_admin_down_never_acts
    pair
    full!
    @client.up('eth0', '10.0.0.2')
    @client.remote_admin_down('eth0', '10.0.0.2')
    deliver
    assert nbr.full?, 'remote AdminDown'
    @client.up('eth0', '10.0.0.2')
    @client.state('eth0', '10.0.0.2', :admin_down)
    deliver
    assert nbr.full?, 'local AdminDown'
    assert_equal 'down', nbr.summary[:bfd]
    assert_empty neighbor_events.select { |d| d[:to] == 'down' }
  end

  # bfdd4r gone: every neighbor stays, one warning until it answers again.
  def test_lost_keeps_neighbors_and_warns_once
    pair
    full!
    @client.up('eth0', '10.0.0.2')
    deliver
    @client.lost
    @client.lost('no bfdd4r on @bfdd4r: Connection refused')
    deliver
    @lab.advance(5)
    assert nbr.full?
    warns = @a.events.select { |e| e.kind == :bfd && e.level == :warn }
    assert_equal 1, warns.size
    assert_equal({ bfdd4r: 'lost' }, warns.first.data)
    assert_equal 'down', nbr.summary[:bfd], 'its state is not known'
    @client.connected
    @client.lost
    deliver
    assert_equal 2, @a.events.count { |e| e.kind == :bfd && e.level == :warn }, 'a new outage warns again'
  end

  # An event for a session no longer wanted, or for no neighbor, is ignored.
  def test_events_for_other_sessions_are_ignored
    pair
    full!
    @client.up('eth0', '10.0.0.9')
    @client.failure('eth0', '10.0.0.9')
    @client.up('eth7', '10.0.0.2')
    @client.failure('eth7', '10.0.0.2')
    deliver
    assert nbr.full?
  end

  # bfd-liveness-detection added or removed on a running interface: the
  # session is asked for or let go, the adjacency stays.
  def test_turned_on_and_off_live
    pair(bfd: nil)
    full!
    changes = nbr.state_changes
    @a.interfaces['eth0'].bfd = { multiplier: 5 }
    assert_equal({ interface: 'eth0', peer: '10.0.0.2', local: '10.0.0.1', detect_mult: 5 }, @client.wanted.values.first)
    @a.interfaces['eth0'].bfd = { multiplier: 3 }
    assert_equal 3, @client.wanted.values.first[:detect_mult], 'new timers ask again'
    @a.interfaces['eth0'].bfd = nil
    assert_empty @client.wanted
    refute nbr.summary.key?(:bfd)
    assert_equal changes, nbr.state_changes
    assert nbr.full?
  end
end
