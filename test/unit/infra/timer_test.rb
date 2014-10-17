require "test/unit"

require "infra/timer"

class TestInfraTimer < Test::Unit::TestCase

  Timer1 = Class.new(Timer)
  Timer2 = Class.new(Timer)
  Timer3 = Class.new(Timer)

  def update(*args)
    @evQ.enq args
  end

  def setup
    @evQ = Queue.new
  end

  def _tests
    assert Timer.new(10)
    t0 = Time.now
    # + notification
    t1 = Timer1.start(1,self)
    assert_equal [:ev_timer_start, :"TestTimer::Timer1"], @evQ.deq
    assert_equal [:ev_timer_expire, :"TestTimer::Timer1"], @evQ.deq
    # - notification
    # + block
    t2 = Timer2.start(1) { @evQ.enq ['DONE', (Time.now-t0).to_int]}
    assert_equal ['DONE',2], @evQ.deq
    # + notificaion
    # + block
    t3 = Timer3.start(1,self) {  @evQ.enq ['DONE', (Time.now-t0).to_int]}
    assert_equal [:ev_timer_start, :"TestTimer::Timer3"], @evQ.deq
    assert_equal ['DONE',3], @evQ.deq
    assert_equal [:ev_timer_expire, :"TestTimer::Timer3"], @evQ.deq
  end
  def test_running?
    t1 = Timer1.new(10)
    assert ! t1.running?
    t1.start 1
    assert t1.running?
  end
  def _test_cancel
    t1 = Timer1.new(10)
    t1.start 1
    assert t1.running?
    t1.cancel
    assert ! t1.running?
    t0 = Time.now
    t1 = Timer.start(3)
    sleep 2
    t1.reset { @evQ.enq ['DONE', (Time.now-t0).to_int]}
    assert_equal ['DONE', 2+3], @evQ.deq
  end
end

class TestPeriodicTimer < Test::Unit::TestCase

  PeriodicTimer1 = Class.new(PeriodicTimer)

  def update(*args)
    @evQ.enq args
  end

  def setup
    @evQ = Queue.new
  end

  def tests
    t0 = Time.now
    p = PeriodicTimer1.start(1,self) {  @evQ.enq ['DONE', (Time.now-t0).to_int]}
    assert_equal [:ev_timer_start, :"TestPeriodicTimer::PeriodicTimer1"], @evQ.deq[0,2]
    assert_equal ['DONE',1], @evQ.deq
    assert_equal [:ev_timer_fire, :"TestPeriodicTimer::PeriodicTimer1"], @evQ.deq[0,2]
    assert_equal ['DONE',2], @evQ.deq
    assert_equal [:ev_timer_fire, :"TestPeriodicTimer::PeriodicTimer1"], @evQ.deq[0,2]
    assert_equal ['DONE',3], @evQ.deq
    assert_equal [:ev_timer_fire, :"TestPeriodicTimer::PeriodicTimer1"], @evQ.deq[0,2]
  end

  def test_stop
    t0 = Time.now
    p = PeriodicTimer1.start(1,self) {  @evQ.enq ['DONE', (Time.now-t0).to_int]}
    assert_equal [:ev_timer_start, :"TestPeriodicTimer::PeriodicTimer1"], @evQ.deq[0,2]
    assert_equal ['DONE',1], @evQ.deq
    assert_equal [:ev_timer_fire, :"TestPeriodicTimer::PeriodicTimer1"], @evQ.deq[0,2]
    assert p.running?
    p.stop
    sleep(1.2)
    assert ! p.running?
  end

end

