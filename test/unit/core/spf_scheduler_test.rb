# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'support/core_lab'

# RFC 8405 back-off, and the routing table the instance keeps with it.
class TestCoreSpfScheduler < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  def setup
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e })
    @runs = []
    @s = SpfScheduler.new(@loop) { |reasons| @runs << [@loop.now.round(3), reasons.map(&:to_s)] }
  end

  def at(t)
    @loop.advance(t - @loop.now)
  end

  def test_first_change_runs_after_the_initial_delay
    @s.trigger(:router, '2.2.2.2')
    assert_equal :short_wait, @s.state
    at(0.049)
    assert_empty @runs
    at(0.05)
    assert_equal [[0.05, ['router 2.2.2.2']]], @runs
  end

  def test_changes_while_a_run_is_due_ride_along
    @s.trigger(:router, 'a')
    at(0.01)
    @s.trigger(:network, 'b')
    @s.trigger(:router, 'a')
    at(0.05)
    assert_equal [[0.05, ['router a', 'network b']]], @runs
  end

  # RFC 8405 section 6 defaults: 50 ms, 200 ms, 5 s, learn 500 ms, holddown 10 s.
  def test_short_then_long_then_quiet
    @s.trigger(:x)          # quiet -> short wait, run at 0.05
    at(0.2)
    @s.trigger(:x)          # short wait: run at 0.4
    at(0.4)
    assert_equal [0.05, 0.4], @runs.map(&:first)
    at(0.5)                 # time to learn is up
    assert_equal :long_wait, @s.state
    at(1.0)
    @s.trigger(:x)          # long wait: run at 6.0
    at(5.999)
    assert_equal 2, @runs.size
    at(6.0)
    assert_equal 6.0, @runs.last.first
    at(11.0)                # 10 s of holddown since the last change
    assert_equal :quiet, @s.state
    @s.trigger(:x)
    at(11.05)
    assert_equal 11.05, @runs.last.first
  end

  # Transition 1 starts the SPF timer only if it is not running: a long
  # wait run still due when holddown ends is not pulled forward.
  def test_quiet_keeps_a_run_already_due
    s = SpfScheduler.new(@loop, learn: 0.5, holddown: 1.0) { @runs << @loop.now.round(3) }
    s.trigger(:x)
    at(0.6)
    s.trigger(:x)           # long wait: run at 5.6
    at(1.7)
    assert_equal :quiet, s.state
    s.trigger(:x)
    at(5.599)
    assert_equal [0.05], @runs
    at(5.6)
    assert_equal [0.05, 5.6], @runs
  end

  def test_holddown_restarts_with_every_change
    @s.trigger(:x)
    9.times do |i|
      at(i + 1.5)
      @s.trigger(:x)
    end
    at(19.0)
    assert_equal :long_wait, @s.state
    at(19.6)
    assert_equal :quiet, @s.state
  end

  def test_settings_are_checked
    assert_raise(ArgumentError) { SpfScheduler.new(@loop, initial: 1, short: 0.5) {} }
    assert_raise(ArgumentError) { SpfScheduler.new(@loop, holddown: 0) {} }
    assert_raise(ArgumentError) { SpfScheduler.new(@loop, bogus: 1) {} }
    assert_raise(ArgumentError) { SpfScheduler.new(@loop, learn: 2, holddown: 2) {} }
    s = SpfScheduler.new(@loop, initial: 0.1, short: 0.1, long: 0.1) { @runs << :custom }
    s.trigger(:x)
    at(0.1)
    assert_equal [:custom], @runs
  end

  def test_run_now_and_stop
    @s.trigger(:x)
    @s.run_now(:clear)
    assert_equal [[0.0, %w[x clear]]], @runs
    assert_nil @s.next_run_in
    @s.trigger(:y)
    @s.stop
    at(5)
    assert_equal 1, @runs.size
    assert_equal :quiet, @s.state
  end

  def test_reasons_are_capped
    50.times { |i| @s.trigger(:router, i.to_s) }
    at(0.05)
    reasons = @runs.last.last
    assert_equal SpfScheduler::MAX_REASONS + 1, reasons.size
    assert_equal 'more 18', reasons.last
  end

  # ---- the instance ----

  #  R1 eth0 ---- 10.0.12.0/24 ---- R2 eth0 ; R2 eth1 ---- 10.0.23.0/30 (p2p) ---- R3
  #  each has a passive loopback
  def chain
    lab = CoreLab.new
    a = lab.segment
    b = lab.segment
    r1 = lab.router('1.1.1.1', [a, '10.0.12.1/24'], [:passive, '1.1.1.1/32'])
    r2 = lab.router('2.2.2.2', [a, '10.0.12.2/24'], [b, '10.0.23.1/30', { type: :p2p }], [:passive, '2.2.2.2/32'])
    r3 = lab.router('3.3.3.3', [b, '10.0.23.2/30', { type: :p2p }], [:passive, '3.3.3.3/32'])
    lab.start
    [lab, r1, r2, r3]
  end

  def route(r, prefix)
    p, len = prefix.split('/')
    r.routes[[Addr.to_i(p), len.to_i]]
  end

  def test_routes_appear_once_the_network_converges
    lab, r1, r2, r3 = chain
    diffs = []
    r1.on_route_change { |d| diffs << d }
    assert lab.run_until(120) { route(r1, '3.3.3.3/32') && route(r3, '1.1.1.1/32') }
    r = route(r1, '3.3.3.3/32')
    assert_equal ['via 10.0.12.2 eth0'], r.next_hops.map(&:to_s)
    assert_equal 30, r.cost, 'LAN 10 + p2p 10 + loopback 10'
    assert_equal ['via 10.0.23.1 eth0'], route(r3, '10.0.12.0/24').next_hops.map(&:to_s)
    assert_equal ['direct eth0'], route(r1, '10.0.12.0/24').next_hops.map(&:to_s)
    assert diffs.sum { |d| d.added.size } >= 5
    assert r1.spf_log.any? { |run| run.reasons.any? { |x| x.kind == :router } }
    refute_nil r2.spf.last_run
  end

  def test_a_lost_link_withdraws_routes_and_stop_clears_them
    lab, r1, r2, r3 = chain
    assert lab.run_until(120) { route(r1, '3.3.3.3/32') }
    removed = []
    r1.on_route_change { |d| removed.concat(d.removed.map(&:dest_s)) }
    r2.remove_interface('eth1')
    assert lab.run_until(60) { route(r1, '3.3.3.3/32').nil? }
    assert_include removed, '3.3.3.3/32'
    assert route(r1, '2.2.2.2/32')
    r1.stop
    assert_empty r1.routes
    assert_equal :stop, r1.spf_log.last.reasons.first.kind
    r3.stop
  end

  def test_a_bad_lsa_is_warned_about_once
    lab, r1, = chain
    assert lab.run_until(120) { route(r1, '3.3.3.3/32') }
    r1.as_lsdb.install(Lsa.build(type: 5, ls_id: '9.0.0.0', advr: '2.2.2.2', seq: 1, body: "\0" * 4))
    r1.compute_routes
    r1.compute_routes
    assert_equal 1, lab.log.count { |l| l.start_with?('1.1.1.1') && l.include?('SPF skipped external 9.0.0.0 2.2.2.2: external body too short') }
    assert_equal r1.spf.runs + 2, r1.stats[:spf_runs], 'two runs by hand, the rest by the scheduler'
  end

  def test_a_metric_change_reroutes_without_bouncing_anything
    lab, r1, r2, = chain
    assert lab.run_until(120) { route(r1, '3.3.3.3/32') }
    r2.interfaces['eth1'].cost = 50
    assert lab.run_until(30) { route(r1, '3.3.3.3/32').cost == 70 }
    assert lab.full?(r1, r2)
  end
end
