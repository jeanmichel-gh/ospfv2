# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/infra/scheduler'

class TestClock < Test::Unit::TestCase
  include OSPFv2

  def test_real_clock_is_monotonic
    c = Clock::Real.new
    a = c.now
    b = c.now
    assert_operator b, :>=, a
    assert_kind_of Time, c.wall
    assert !c.fake?
  end

  def test_fake_clock_moves_only_when_told
    c = Clock::Fake.new(wall: Time.utc(2026, 10, 26, 12))
    assert_equal 0.0, c.now
    c.advance(1.5)
    assert_equal 1.5, c.now
    c.set(10)
    assert_equal 10.0, c.now
    assert_equal Time.utc(2026, 10, 26, 12, 0, 10), c.wall
    assert c.fake?
  end

  def test_fake_clock_never_goes_back
    c = Clock::Fake.new(now: 5)
    assert_raise(ArgumentError) { c.advance(-1) }
    assert_raise(ArgumentError) { c.set(4) }
  end
end

class TestScheduler < Test::Unit::TestCase
  include OSPFv2

  def setup
    @clock = Clock::Fake.new
    @s = Scheduler.new(@clock, random: Random.new(1))
    @log = []
  end

  # Moves the fake clock to each deadline up to +t+ and fires what is due.
  def run_to(t)
    while (d = @s.next_deadline) && d <= t
      @clock.set(d) if d > @clock.now
      @s.run_next
    end
    @clock.set(t)
  end

  def test_one_shot_fires_once_at_its_deadline
    t = @s.after(5, :x) { @log << @clock.now }
    assert t.active?
    assert_equal 5.0, t.deadline
    run_to(4.9)
    assert_equal [], @log
    run_to(20)
    assert_equal [5.0], @log
    assert !t.active?
    assert_nil @s.next_deadline
    assert_equal 1, t.fired
  end

  def test_timers_fire_in_deadline_order_then_arming_order
    @s.after(3) { @log << :c }
    @s.after(1) { @log << :a }
    @s.after(3) { @log << :d }
    @s.after(2) { @log << :b }
    @s.after(3) { @log << :e }
    run_to(10)
    assert_equal %i[a b c d e], @log
  end

  def test_run_due_fires_everything_due
    5.times { |i| @s.after(i) { @log << i } }
    @clock.set(2)
    assert_equal 3, @s.run_due
    assert_equal [0, 1, 2], @log
    assert_equal 2, @s.size
  end

  def test_cancel
    t = @s.after(1) { @log << :fired }
    t.cancel
    assert !t.active?
    assert_nil t.remaining
    assert_equal 0, @s.size
    run_to(5)
    assert_equal [], @log
  end

  def test_restart_pushes_the_deadline_out
    # The inactivity timer pattern: every hello restarts it.
    t = @s.after(40, :inactivity) { @log << @clock.now }
    [10, 20, 30].each do |at|
      run_to(at)
      t.restart
    end
    run_to(69)
    assert_equal [], @log
    run_to(100)
    assert_equal [70.0], @log
    assert_equal 1, t.fired
  end

  def test_restart_with_a_one_off_delay
    t = @s.after(40) { @log << @clock.now }
    t.restart(2)
    run_to(50)
    assert_equal [2.0], @log
    assert_equal 40, t.interval
  end

  def test_idle_timer_is_armed_by_restart
    t = @s.timer(5) { @log << @clock.now }
    assert !t.active?
    run_to(10)
    t.restart
    run_to(20)
    assert_equal [15.0], @log
  end

  def test_restarted_timer_leaves_no_ghost_firing
    t = @s.after(5) { @log << @clock.now }
    t.restart(1)
    t.restart(3)
    run_to(10)
    assert_equal [3.0], @log
  end

  def test_periodic_does_not_drift
    @s.every(10, :hello) { @log << @clock.now }
    # Fire each one late, as a busy loop would.
    5.times do |i|
      @clock.set(10 * (i + 1) + 0.7)
      @s.run_due
    end
    assert_equal [10.7, 20.7, 30.7, 40.7, 50.7], @log
    assert_equal 60.0, @s.next_deadline
  end

  def test_periodic_far_behind_does_not_burst
    @s.every(10) { @log << @clock.now }
    @clock.set(95)
    assert_equal 1, @s.run_due
    assert_equal 105.0, @s.next_deadline
  end

  def test_periodic_jitter_stays_within_bounds
    t = @s.every(10, jitter: 0.25) { @log << @clock.now }
    run_to(1000)
    gaps = ([0.0] + @log).each_cons(2).map { |a, b| b - a }
    assert_operator gaps.size, :>, 90
    assert gaps.all? { |g| g > 7.5 - 1e-9 && g <= 10.0 }, gaps.inspect
    assert_operator gaps.uniq.size, :>, 1
    assert t.periodic?
  end

  def test_periodic_can_be_created_idle
    t = @s.every(5, start: false) { @log << @clock.now }
    run_to(20)
    assert_equal [], @log
    t.restart
    run_to(31)
    assert_equal [25.0, 30.0], @log
  end

  def test_callback_can_cancel_itself_and_others
    other = nil
    p = @s.every(1) do |t|
      @log << @clock.now
      t.cancel if @clock.now >= 3
      other.cancel
    end
    other = @s.after(2) { @log << :other }
    run_to(10)
    assert_equal [1.0, 2.0, 3.0], @log
    assert !p.active?
  end

  def test_callback_can_arm_new_timers
    @s.after(1) { @s.after(1) { @log << @clock.now } }
    run_to(5)
    assert_equal [2.0], @log
  end

  def test_many_timers
    srand_rng = Random.new(7)
    deadlines = Array.new(5_000) { srand_rng.rand(1000.0) }
    deadlines.each { |d| @s.after(d) { @log << @clock.now } }
    run_to(1000)
    assert_equal deadlines.sort, @log
  end

  def test_rejects_bad_arguments
    assert_raise(ArgumentError) { @s.after(-1) {} }
    assert_raise(ArgumentError) { @s.after('1') {} }
    assert_raise(ArgumentError) { @s.after(1) }
    assert_raise(ArgumentError) { @s.every(0) {} }
    assert_raise(ArgumentError) { @s.every(1, jitter: 1.0) {} }
  end

  def test_inspect
    t = @s.after(5, :dead) {}
    assert_match(/dead in 5\.000s/, t.inspect)
    t.cancel
    assert_match(/dead idle/, t.inspect)
  end
end
