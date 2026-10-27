# frozen_string_literal: true

require_relative 'clock'
require_relative 'scheduler'

module OSPFv2
  # One thread that owns all protocol state.
  #
  # Interfaces, neighbors, the LSDB and SPF are only ever touched from the
  # loop thread, so they need no locks. Everything else talks to the loop:
  #
  # * socket reader threads hand packets in with #post
  # * the CLI and the management API use #call, which waits for the answer
  # * timers come from #after and #every and run on the loop thread
  #
  # In production the loop runs on its own thread with a real clock:
  #
  #   loop = EventLoop.new
  #   loop.start
  #   transport.start { |bytes, from| loop.post { iface.receive(bytes, from) } }
  #
  # In tests it runs on the test thread with a fake clock. Nothing waits on
  # real time, and runs are repeatable:
  #
  #   loop = EventLoop.new(clock: Clock::Fake.new)
  #   loop.run_until(60) { a.full? && b.full? }   # up to 60 s of protocol time
  class EventLoop
    # An event handler raised. The loop logs it and keeps going.
    class Error < StandardError; end

    # #drain or #run_until hit their limit.
    class Stalled < StandardError; end

    MAX_EVENTS_PER_DRAIN = 1_000_000

    # Events the loop thread handles before it checks timers again, so a
    # packet flood cannot starve hellos and dead timers.
    BATCH = 100

    # Most events #offer will queue. Past this, packets are dropped as a
    # full socket buffer would drop them.
    MAX_QUEUE = 10_000

    attr_reader :clock, :scheduler, :errors, :dropped

    # clock:    Clock::Real (default) or Clock::Fake
    # on_error: called with the exception when a handler raises. The
    #           default prints it. Tests pass ->(e) { raise e }.
    # random:   source for timer jitter. Seed it for repeatable tests.
    def initialize(clock: Clock::Real.new, on_error: nil, random: Random.new, name: 'ospfv2-loop')
      @clock = clock
      @scheduler = Scheduler.new(clock, random: random)
      @on_error = on_error || method(:default_error)
      @name = name
      @queue = []
      @lock = Mutex.new
      @wakeup = ConditionVariable.new
      @thread = nil
      @stop = false
      @errors = 0
      @dropped = 0
    end

    def now
      @clock.now
    end

    # -- from any thread --

    # Queues +block+ to run on the loop thread. Returns at once.
    def post(&block)
      raise ArgumentError, 'block required' unless block
      @lock.synchronize do
        @queue << block
        @wakeup.signal
      end
      self
    end

    # Like #post, but drops the event and returns false when MAX_QUEUE
    # events are already waiting. Socket readers use this.
    def offer(&block)
      raise ArgumentError, 'block required' unless block
      @lock.synchronize do
        if @queue.size >= MAX_QUEUE
          @dropped += 1
          return false
        end
        @queue << block
        @wakeup.signal
      end
      true
    end

    # Runs +block+ on the loop thread and returns its value. Exceptions are
    # raised in the caller, not reported to on_error. Runs inline when
    # called on the loop thread, or when no loop thread is running (tests
    # driving a fake clock).
    def call(timeout: 10, &block)
      raise ArgumentError, 'block required' unless block
      return block.call if !running? || on_loop_thread?

      reply = Reply.new
      post do
        reply.set(:ok, block.call)
      rescue Exception => e # rubocop:disable Lint/RescueException
        reply.set(:error, e)
      end
      kind, value = reply.wait(timeout)
      raise Stalled, "loop did not answer within #{timeout}s" if kind.nil?
      raise value if kind == :error
      value
    end

    def running?
      @thread&.alive? || false
    end

    def on_loop_thread?
      Thread.current == @thread
    end

    # Starts the loop on its own thread.
    def start
      raise ArgumentError, 'a fake clock loop is driven with #advance or #run_until, not a thread' if @clock.fake?
      return self if running?
      @stop = false
      @thread = Thread.new do
        Thread.current.name = @name
        Thread.current.report_on_exception = true
        run
      end
      self
    end

    # Stops the loop. Events still queued are dropped. Joins the loop thread
    # unless called from it.
    def stop
      @lock.synchronize do
        @stop = true
        @wakeup.signal
      end
      @thread.join unless @thread.nil? || on_loop_thread?
      @thread = nil unless on_loop_thread?
      self
    end

    # -- from the loop thread --

    # One shot timer. See Scheduler#after.
    def after(delay, name = nil, &block)
      @scheduler.after(delay, name, &guarded(block))
    end

    # Idle one shot timer, armed with Timer#restart. See Scheduler#timer.
    def timer(delay, name = nil, &block)
      @scheduler.timer(delay, name, &guarded(block))
    end

    # Periodic timer. See Scheduler#every.
    def every(interval, name = nil, jitter: 0.0, start: true, &block)
      @scheduler.every(interval, name, jitter: jitter, start: start, &guarded(block))
    end

    # The body of the loop thread. Blocks until #stop.
    def run
      until @stop
        begin
          ran = run_events(BATCH)
          break if @stop
          # One due timer per turn, then events again: timers and packets
          # take turns however busy the queue is.
          next if @scheduler.run_next(@clock.now)
          next if ran == BATCH

          deadline = @scheduler.next_deadline
          @lock.synchronize do
            next unless @queue.empty? && !@stop
            if deadline.nil?
              @wakeup.wait(@lock)
            else
              wait = deadline - @clock.now
              @wakeup.wait(@lock, wait) if wait.positive?
            end
          end
        rescue StandardError => e
          report(e) # the loop thread never dies of a handler bug
        end
      end
    end

    # Runs queued events, including events they queue, until none are left.
    # Returns how many ran.
    def drain(limit: MAX_EVENTS_PER_DRAIN)
      n = 0
      while !@stop && (block = next_event)
        dispatch(block)
        n += 1
        raise Stalled, "more than #{limit} events in one drain: is something looping?" if n > limit
      end
      n
    end

    # -- fake clock only: drive the loop from the test thread --

    # Moves time forward by +seconds+, firing timers in order. Events that
    # timers post run before the next timer, as on a real loop.
    def advance(seconds)
      fake_only!
      target = @clock.now + seconds
      drain
      while (deadline = @scheduler.next_deadline) && deadline <= target
        @clock.set(deadline) if deadline > @clock.now
        @scheduler.run_next(@clock.now)
        drain
      end
      @clock.set(target)
      drain
      self
    end

    # Advances in +step+ second increments until the block returns true.
    # Returns the protocol time it took. Raises Stalled after +timeout+.
    def run_until(timeout, step: 0.1)
      fake_only!
      start = @clock.now
      drain
      until yield
        elapsed = @clock.now - start
        raise Stalled, "condition not met after #{elapsed.round(1)}s of protocol time" if elapsed >= timeout
        advance([step, timeout - elapsed].min)
      end
      @clock.now - start
    end

    private

    def next_event
      @lock.synchronize { @queue.shift }
    end

    # Runs at most +max+ queued events. Returns how many ran.
    def run_events(max)
      n = 0
      while n < max && !@stop && (block = next_event)
        dispatch(block)
        n += 1
      end
      n
    end

    def dispatch(block)
      block.call
    rescue StandardError => e
      report(e)
    end

    def guarded(block)
      raise ArgumentError, 'block required' unless block
      lambda do |t|
        block.call(t)
      rescue StandardError => e
        report(e)
      end
    end

    def report(e)
      @errors += 1
      @on_error.call(e)
    end

    def default_error(e)
      where = e.backtrace&.first(5)&.join("\n  ")
      warn "ospfv2: #{e.class}: #{e.message}\n  #{where}"
    end

    def fake_only!
      raise ArgumentError, 'advance and run_until need a Clock::Fake' unless @clock.fake?
    end

    # A one-value mailbox for #call. Queue#pop(timeout:) needs Ruby 3.2,
    # and the gem still supports 3.1.
    class Reply
      def initialize
        @lock = Mutex.new
        @cond = ConditionVariable.new
        @value = nil
      end

      def set(kind, value)
        @lock.synchronize do
          @value = [kind, value]
          @cond.signal
        end
      end

      def wait(timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @lock.synchronize do
          until @value
            left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break unless left.positive?
            @cond.wait(@lock, left)
          end
          @value
        end
      end
    end
  end
end
