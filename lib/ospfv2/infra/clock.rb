# frozen_string_literal: true

module OSPFv2
  # Where the router reads time.
  #
  # Protocol code never calls Time.now. It asks a clock, so tests can swap
  # in a Fake clock and run minutes of protocol time in milliseconds.
  #
  # #now  is monotonic seconds as a Float. Use it for timers and ages.
  # #wall is a Time. Use it only for logs, display, and values that must
  # keep growing across a restart (the cryptographic sequence number).
  module Clock
    class Real
      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def wall
        Time.now
      end

      def fake?
        false
      end
    end

    # A clock that moves only when told to.
    class Fake
      attr_reader :now

      def initialize(now: 0.0, wall: Time.utc(2026, 1, 1))
        @now = now.to_f
        @wall0 = wall
      end

      def wall
        @wall0 + @now
      end

      def advance(seconds)
        raise ArgumentError, "cannot move a clock back (#{seconds})" if seconds.negative?
        @now += seconds
      end

      def set(time)
        raise ArgumentError, "cannot move a clock back (#{time} < #{@now})" if time < @now
        @now = time.to_f
      end

      def fake?
        true
      end
    end
  end
end
