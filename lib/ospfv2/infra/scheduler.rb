# frozen_string_literal: true

require_relative 'clock'

module OSPFv2
  # Timers for the event loop, kept in one binary heap.
  #
  # The scheduler never sleeps and never starts a thread. The loop asks it
  # for #next_deadline, waits until then, and calls #run_next. Timer code
  # runs on the loop thread, so it can touch protocol state freely.
  #
  #   s = Scheduler.new(clock)
  #   t = s.after(40, :inactivity) { neighbor_down }
  #   t.restart                     # a hello arrived: push the deadline out
  #   s.every(10, :hello, jitter: 0.1) { send_hello }
  #
  # Not thread safe. Only the loop thread touches it.
  class Scheduler
    class Timer
      attr_reader :name, :interval, :deadline, :fired

      def initialize(scheduler, name, interval, periodic, jitter, block)
        @scheduler = scheduler
        @name = name
        @interval = interval
        @periodic = periodic
        @jitter = jitter
        @block = block
        @deadline = nil
        @generation = 0
        @fired = 0
      end

      def periodic?
        @periodic
      end

      def active?
        !@deadline.nil?
      end

      # Seconds until it fires, or nil when it is not armed.
      def remaining
        @deadline && [@deadline - @scheduler.now, 0.0].max
      end

      def cancel
        @scheduler.disarm(self)
        self
      end

      # Arms the timer again, from now. A periodic timer keeps its period
      # unless +delay+ is given for the next shot only.
      def restart(delay = nil)
        @scheduler.arm(self, delay || first_delay)
        self
      end

      def inspect
        state = active? ? format('in %.3fs', remaining) : 'idle'
        "#<#{self.class.name} #{@name} #{state}>"
      end

      # -- used by Scheduler only --

      attr_accessor :generation # :nodoc:

      def first_delay # :nodoc:
        @periodic ? jittered(@interval) : @interval
      end

      def set_deadline(deadline) # :nodoc:
        @deadline = deadline
      end

      # Called by the scheduler when the timer is due.
      def fire # :nodoc:
        @fired += 1
        due = @deadline
        if @periodic
          # Schedule from the old deadline, not from now, so a busy loop
          # does not make hellos drift. If we fell more than a period
          # behind, start again from now instead of firing a burst.
          nxt = due + jittered(@interval)
          nxt = @scheduler.now + jittered(@interval) if nxt <= @scheduler.now
          @scheduler.arm_at(self, nxt)
        else
          @scheduler.disarm(self)
        end
        @block.call(self)
      end

      private

      # RFC 2328 does not require jitter, but sending every hello on the
      # same tick across a segment is what jitter exists to avoid.
      def jittered(interval)
        return interval if @jitter.zero?
        interval * (1.0 - @jitter * @scheduler.random.rand)
      end
    end

    attr_reader :clock, :random

    def initialize(clock = Clock::Real.new, random: Random.new)
      @clock = clock
      @random = random
      @heap = []
      @seq = 0
    end

    def now
      @clock.now
    end

    # One shot timer. The block gets the timer.
    def after(delay, name = nil, &block)
      check_delay(delay)
      raise ArgumentError, 'block required' unless block
      Timer.new(self, name, delay, false, 0.0, block).tap { |t| arm(t, delay) }
    end

    # One shot timer that is created idle. Arm it with #restart.
    def timer(delay, name = nil, &block)
      check_delay(delay)
      raise ArgumentError, 'block required' unless block
      Timer.new(self, name, delay, false, 0.0, block)
    end

    # Periodic timer. +jitter+ is a fraction (0.1 = up to 10% early).
    # +start+ false creates it idle; arm it with #restart.
    def every(interval, name = nil, jitter: 0.0, start: true, &block)
      check_delay(interval)
      raise ArgumentError, 'interval must be > 0' unless interval.positive?
      raise ArgumentError, "jitter must be in 0...1 (#{jitter})" unless (0.0...1.0).cover?(jitter)
      raise ArgumentError, 'block required' unless block
      t = Timer.new(self, name, interval, true, jitter.to_f, block)
      t.restart if start
      t
    end

    # Absolute time of the next armed timer, or nil.
    def next_deadline
      drop_stale
      @heap.first&.first
    end

    # Fires the earliest timer if it is due at +now+. Returns it, or nil.
    def run_next(now = self.now)
      drop_stale
      top = @heap.first
      return unless top && top[0] <= now
      pop
      top[2].fire
      top[2]
    end

    # Fires every timer due at +now+, earliest first. Returns how many.
    def run_due(now = self.now)
      n = 0
      n += 1 while run_next(now)
      n
    end

    # Number of armed timers.
    def size
      drop_stale
      @heap.count { |_, _, t, gen| t.generation == gen }
    end

    # -- used by Timer --

    def arm(timer, delay) # :nodoc:
      check_delay(delay)
      arm_at(timer, now + delay)
    end

    def arm_at(timer, deadline) # :nodoc:
      timer.generation += 1
      timer.set_deadline(deadline)
      push([deadline, @seq += 1, timer, timer.generation])
    end

    def disarm(timer) # :nodoc:
      # The heap entry stays and is skipped later: cancelling is O(1).
      timer.generation += 1
      timer.set_deadline(nil)
    end

    private

    def check_delay(delay)
      raise ArgumentError, "delay must be a number >= 0 (#{delay.inspect})" unless delay.is_a?(Numeric) && !delay.negative?
    end

    def drop_stale
      pop while (top = @heap.first) && top[2].generation != top[3]
    end

    # Entries are [deadline, seq, timer, generation]. seq keeps timers
    # with the same deadline in the order they were armed.
    def push(entry)
      @heap << entry
      i = @heap.size - 1
      while i.positive?
        parent = (i - 1) / 2
        break unless less(@heap[i], @heap[parent])
        @heap[i], @heap[parent] = @heap[parent], @heap[i]
        i = parent
      end
    end

    def pop
      last = @heap.pop
      return last if @heap.empty?
      top = @heap[0]
      @heap[0] = last
      i = 0
      n = @heap.size
      loop do
        l = 2 * i + 1
        r = l + 1
        m = i
        m = l if l < n && less(@heap[l], @heap[m])
        m = r if r < n && less(@heap[r], @heap[m])
        break if m == i
        @heap[i], @heap[m] = @heap[m], @heap[i]
        i = m
      end
      top
    end

    def less(a, b)
      a[0] < b[0] || (a[0] == b[0] && a[1] < b[1])
    end
  end
end
