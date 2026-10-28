# frozen_string_literal: true

module OSPFv2
  module Core
    # When to run SPF: the back-off algorithm of RFC 8405.
    #
    # The first change after a quiet spell runs SPF almost at once
    # (initial delay). Changes that keep coming within time-to-learn run
    # it at the short delay; past that the network is taken to be unstable
    # and SPF runs at the long delay. After holddown with no change at all
    # it is quiet again.
    #
    #   s = SpfScheduler.new(loop) { |reasons| compute(reasons) }
    #   s.trigger(:router, '2.2.2.2')
    #
    # Every router in an area using the same values converges together,
    # which is the point of the RFC. The defaults are its suggested values
    # (section 6): 50 ms, 200 ms, 5 s, 500 ms to learn, 10 s of holddown.
    class SpfScheduler
      DEFAULTS = { initial: 0.05, short: 0.2, long: 5.0, learn: 0.5, holddown: 10.0 }.freeze
      MAX_REASONS = 32

      # What set off a run: LSA types, or a local change.
      Reason = Struct.new(:kind, :detail) do
        def to_s = detail ? "#{kind} #{detail}" : kind.to_s
      end

      attr_reader :state, :settings, :runs, :last_run

      def initialize(loop, **settings, &compute)
        @loop = loop
        @settings = DEFAULTS.merge(settings)
        check(@settings)
        @compute = compute
        @state = :quiet
        @reasons = []
        @dropped = 0
        @runs = 0
        @last_run = nil
        @spf = loop.timer(@settings[:initial], :spf) { run }
        @learn = loop.timer(@settings[:learn], :spf_learn) { @state = :long_wait if @state == :short_wait }
        @holddown = loop.timer(@settings[:holddown], :spf_holddown) do
          @state = :quiet
          @learn.cancel
        end
      end

      # Something that can change routes happened (RFC 8405 section 6).
      def trigger(kind, detail = nil)
        note(kind, detail)
        case @state
        when :quiet
          @spf.restart(@settings[:initial]) unless @spf.active?
          @learn.restart
          @holddown.restart
          @state = :short_wait
        when :short_wait
          @holddown.restart
          @spf.restart(@settings[:short]) unless @spf.active?
        when :long_wait
          @holddown.restart
          @spf.restart(@settings[:long]) unless @spf.active?
        end
        self
      end

      # Its timers by name, for show timers.
      def timers = { spf: @spf, spf_learn: @learn, spf_holddown: @holddown }

      # Seconds until the next run, or nil if none is due.
      def next_run_in = @spf.remaining

      def pending? = @spf.active?

      # Runs now, whatever the state. For clear commands and tests.
      def run_now(kind = :manual)
        note(kind, nil)
        @spf.cancel
        run
      end

      def stop
        [@spf, @learn, @holddown].each(&:cancel)
        @state = :quiet
        @reasons.clear
        @dropped = 0
      end

      private

      def note(kind, detail)
        r = Reason.new(kind, detail)
        if @reasons.size < MAX_REASONS
          @reasons << r unless @reasons.include?(r)
        else
          @dropped += 1
        end
      end

      def run
        reasons = @reasons
        reasons += [Reason.new(:more, @dropped.to_s)] if @dropped.positive?
        @reasons = []
        @dropped = 0
        @runs += 1
        @last_run = @loop.now
        @compute.call(reasons)
      end

      def check(s)
        unknown = s.keys - DEFAULTS.keys
        raise ArgumentError, "unknown SPF setting #{unknown.first}" unless unknown.empty?
        s.each { |k, v| raise ArgumentError, "SPF #{k} must be a positive number" unless v.is_a?(Numeric) && v.positive? }
        raise ArgumentError, 'SPF delays must be initial <= short <= long' unless s[:initial] <= s[:short] && s[:short] <= s[:long]
        raise ArgumentError, 'SPF holddown must be longer than time to learn' unless s[:holddown] > s[:learn]
      end
    end
  end
end
