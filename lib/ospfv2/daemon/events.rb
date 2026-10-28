# frozen_string_literal: true

require 'time'

module OSPFv2
  class Daemon
    # The daemon's event stream. Events from the router core, and the
    # daemon's own (commits), get a sequence number and go to every
    # subscriber. The last BACKLOG are kept, so a subscriber can catch up
    # from a number it saw before.
    #
    #   sub = events.subscribe(kinds: %w[neighbor spf], since: 0)
    #   sub.pop(timeout: 15)   # => event Hash, or nil after the timeout
    #   sub.close
    #
    # Publishing never blocks: it runs on the router's loop thread. A
    # subscriber that falls MAX_QUEUE events behind loses the oldest, and
    # its next pop returns an :overflow event saying how many.
    class Events
      BACKLOG = 2000
      MAX_QUEUE = 10_000

      KINDS = %w[neighbor interface dr drop spf spf_skipped routes lsa router virtual_link commit log].freeze

      attr_reader :seq

      def initialize
        @seq = 0
        @backlog = []
        @subscribers = []
        @lock = Mutex.new
      end

      # Publishes one event. +fields+: time (a Time), level, kind, message,
      # interface and data. Returns the event Hash.
      def publish(time:, level:, kind:, message:, interface: nil, data: {})
        @lock.synchronize do
          @seq += 1
          ev = { seq: @seq, time: time.utc.iso8601(3), level: level.to_s, kind: kind.to_s,
                 interface: interface, message: message, data: data }
          @backlog << ev
          @backlog.shift(@backlog.size - BACKLOG) if @backlog.size > BACKLOG
          @subscribers.each { |s| s.push(ev) }
          ev
        end
      end

      # A Subscription to events of +kinds+ (all when nil), first replaying
      # the kept events numbered above +since+ (none when nil).
      def subscribe(kinds: nil, since: nil)
        kinds = kinds&.map(&:to_s)
        unknown = Array(kinds) - KINDS
        raise ArgumentError, "unknown event kind #{unknown.join(', ')}; kinds: #{KINDS.join(', ')}" unless unknown.empty?
        @lock.synchronize do
          sub = Subscription.new(self, kinds)
          replay = since ? @backlog.select { |e| e[:seq] > since.to_i && sub.wants?(e) } : []
          replay.each { |e| sub.push(e) }
          @subscribers << sub
          [sub, replay.size]
        end
      end

      def unsubscribe(sub)
        @lock.synchronize { @subscribers.delete(sub) }
      end

      def subscribers
        @lock.synchronize { @subscribers.size }
      end

      # Events of one subscriber, waiting to be read.
      class Subscription
        attr_reader :dropped

        def initialize(events, kinds)
          @events = events
          @kinds = kinds
          @queue = []
          @dropped = 0
          @lock = Mutex.new
          @ready = ConditionVariable.new
          @closed = false
        end

        def wants?(ev) = @kinds.nil? || @kinds.include?(ev[:kind])

        def push(ev)
          return unless wants?(ev)
          @lock.synchronize do
            return if @closed
            @queue << ev
            if @queue.size > MAX_QUEUE
              @queue.shift
              @dropped += 1
            end
            @ready.signal
          end
        end

        # The next event, or nil after +timeout+ seconds, or nil at once
        # when closed. After a loss, first an overflow event.
        def pop(timeout: nil)
          @lock.synchronize do
            if @dropped.positive?
              n = @dropped
              @dropped = 0
              return { seq: nil, time: Time.now.utc.iso8601(3), level: 'warn', kind: 'overflow', interface: nil,
                       message: "#{n} event(s) dropped: reading too slowly", data: { dropped: n } }
            end
            @ready.wait(@lock, timeout) if @queue.empty? && !@closed
            @queue.shift
          end
        end

        def size = @lock.synchronize { @queue.size }

        def close
          @lock.synchronize do
            @closed = true
            @queue.clear
            @ready.broadcast
          end
          @events.unsubscribe(self)
        end

        def closed? = @closed
      end
    end
  end
end
