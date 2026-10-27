# frozen_string_literal: true

require 'test/unit'
require 'timeout'
require 'ospfv2/infra/event_loop'
require 'ospfv2/infra/transport'

# The loop driven from the test thread with a fake clock.
class TestEventLoopFake < Test::Unit::TestCase
  include OSPFv2

  def setup
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e }, random: Random.new(1))
    @log = []
  end

  def test_post_and_drain
    @loop.post { @log << 1 }
    @loop.post { @log << 2; @loop.post { @log << 3 } }
    assert_equal [], @log
    assert_equal 3, @loop.drain
    assert_equal [1, 2, 3], @log
  end

  def test_advance_fires_timers_at_their_deadline
    @loop.after(5) { @log << [:once, @loop.now] }
    @loop.every(2) { @log << [:tick, @loop.now] }
    @loop.advance(6)
    assert_equal [[:tick, 2.0], [:tick, 4.0], [:once, 5.0], [:tick, 6.0]], @log
    assert_equal 6.0, @loop.now
  end

  def test_events_posted_by_a_timer_run_before_the_next_timer
    @loop.after(1) { @loop.post { @log << [:event, @loop.now] } }
    @loop.after(1) { @log << [:second_timer, @loop.now] }
    @loop.after(2) { @log << [:later, @loop.now] }
    @loop.advance(3)
    assert_equal [[:event, 1.0], [:second_timer, 1.0], [:later, 2.0]], @log
  end

  def test_call_runs_inline_without_a_loop_thread
    assert_equal 42, @loop.call { 6 * 7 }
  end

  def test_run_until
    @loop.after(12.3) { @log << :done }
    took = @loop.run_until(60) { @log.include?(:done) }
    assert_in_delta 12.3, took, 0.1
  end

  def test_run_until_raises_when_the_condition_never_holds
    e = assert_raise(EventLoop::Stalled) { @loop.run_until(5) { false } }
    assert_match(/5\.0s/, e.message)
    assert_in_delta 5.0, @loop.now, 1e-9
  end

  def test_minutes_of_protocol_time_take_no_real_time
    hellos = 0
    @loop.every(10, jitter: 0.1) { hellos += 1 }
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @loop.advance(24 * 3600)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 2
    assert_operator hellos, :>=, 8640
  end

  def test_drain_stops_a_ping_pong
    ping = -> { @loop.post { ping.call } }
    ping.call
    assert_raise(EventLoop::Stalled) { @loop.drain(limit: 1000) }
  end

  def test_errors_are_reported_and_the_loop_goes_on
    seen = []
    loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { seen << e.message })
    loop.post { raise 'boom' }
    loop.post { @log << :after_boom }
    loop.after(1) { raise 'timer boom' }
    loop.after(2) { @log << :after_timer_boom }
    loop.advance(3)
    assert_equal %w[boom timer\ boom], seen
    assert_equal %i[after_boom after_timer_boom], @log
    assert_equal 2, loop.errors
  end

  def test_fake_loop_cannot_start_a_thread
    assert_raise(ArgumentError) { @loop.start }
  end

  def test_real_loop_cannot_advance
    real = EventLoop.new
    assert_raise(ArgumentError) { real.advance(1) }
    assert_raise(ArgumentError) { real.run_until(1) { true } }
  end

  # Two endpoints on an in-memory segment, both driven by one fake loop.
  # This is how router tests will run: transports post into the loop,
  # handlers reply through the transport, timers drive retransmits.
  def test_transport_packets_flow_through_the_loop
    hub = Transport::Hub.new
    a = Transport::Loopback.new(hub, '10.0.0.1')
    b = Transport::Loopback.new(hub, '10.0.0.2')
    a.start { |bytes, from| @loop.post { @log << [:a, bytes, from, @loop.now] } }
    b.start do |bytes, from|
      @loop.post do
        @log << [:b, bytes, from, @loop.now]
        b.send_packet("pong #{bytes}", from)
      end
    end
    @loop.every(10) { a.send_packet('ping', AllSPFRouters) }
    @loop.advance(25)
    assert_equal [
      [:b, 'ping', '10.0.0.1', 10.0], [:a, 'pong ping', '10.0.0.2', 10.0],
      [:b, 'ping', '10.0.0.1', 20.0], [:a, 'pong ping', '10.0.0.2', 20.0]
    ], @log
  end
end

# The loop on its own thread with the real clock.
class TestEventLoopThread < Test::Unit::TestCase
  include OSPFv2

  def setup
    @errors = Thread::Queue.new
    @loop = EventLoop.new(on_error: ->(e) { @errors << e }).start
  end

  def teardown
    @loop.stop
  end

  def test_call_returns_the_value_from_the_loop_thread
    thread = @loop.call { Thread.current }
    assert_not_equal Thread.current, thread
    assert_equal 'ospfv2-loop', thread.name
    assert @loop.running?
  end

  def test_call_raises_in_the_caller
    assert_raise(ZeroDivisionError) { @loop.call { 1 / 0 } }
    assert @errors.empty?, 'errors from #call go to the caller, not on_error'
    assert_equal 2, @loop.call { 1 + 1 }
  end

  def test_call_from_the_loop_thread_runs_inline
    assert_equal :inner, @loop.call { @loop.call { :inner } }
  end

  def test_post_from_many_threads
    n = 0
    threads = Array.new(8) { Thread.new { 500.times { @loop.post { n += 1 } } } }
    threads.each(&:join)
    assert_equal 4000, @loop.call { n }
  end

  def test_timers_fire_on_the_loop_thread
    q = Thread::Queue.new
    @loop.call { @loop.after(0.05) { q << Thread.current.name } }
    assert_equal 'ospfv2-loop', Timeout.timeout(2) { q.pop }
  end

  def test_periodic_timer_keeps_firing
    q = Thread::Queue.new
    t = @loop.call { @loop.every(0.02) { q << :tick } }
    Timeout.timeout(2) { 5.times { q.pop } }
    @loop.call { t.cancel }
    assert_operator t.fired, :>=, 5
  end

  def test_a_new_earlier_timer_wakes_a_sleeping_loop
    q = Thread::Queue.new
    @loop.call { @loop.after(60) {} }
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @loop.post { @loop.after(0.05) { q << :early } }
    Timeout.timeout(2) { q.pop }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 1
  end

  def test_errors_do_not_kill_the_loop
    @loop.post { raise 'boom' }
    e = Timeout.timeout(2) { @errors.pop }
    assert_equal 'boom', e.message
    assert_equal :alive, @loop.call { :alive }
  end

  def test_stop_and_restart
    @loop.stop
    assert !@loop.running?
    assert_equal :inline, @loop.call { :inline }
    @loop.start
    assert @loop.running?
    assert_not_equal Thread.current, @loop.call { Thread.current }
  end

  def test_stop_from_the_loop_thread
    @loop.post { @loop.stop }
    Timeout.timeout(2) { sleep 0.01 while @loop.running? }
    assert !@loop.running?
  end

  def test_call_times_out_when_the_loop_is_stuck
    @loop.post { sleep 0.5 }
    assert_raise(EventLoop::Stalled) { @loop.call(timeout: 0.05) { :late } }
  end
end
