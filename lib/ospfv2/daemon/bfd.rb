# frozen_string_literal: true

module OSPFv2
  class Daemon
    # ospfd's link to bfdd4r: a BFD::Client (bfd4r), and one thread that
    # waits on its sockets and polls it. What it polls goes to the event
    # loop with post, which never drops, and Core::Bfd acts on it there.
    #
    #   link = BfdLink.new(client, loop: loop) { |events| loop.post { bfd.handle(events) } }
    #   link.want(interface: 'eth1', peer: '10.0.12.2', local: '10.0.12.1')
    #
    # BFD::Client keeps no lock: want and drop come from the loop thread,
    # poll from this one, so a mutex takes them in turn. None of them
    # blocks. The thread starts with the first want, so an ospfd with no
    # bfd-liveness-detection never looks for bfdd4r.
    class BfdLink
      WAIT = 0.25 # seconds between polls when nothing is readable

      attr_reader :client

      # client: a BFD::Client, or a test's stand-in
      # loop:   the EventLoop whose clock poll is given
      # sink:   called on this link's thread with each non-empty batch
      def initialize(client, loop:, &sink)
        @client = client
        @loop = loop
        @sink = sink
        @lock = Mutex.new
        @thread = nil
        @stop = false
      end

      def want(**params)
        @lock.synchronize { @client.want(**params) }
        start
        self
      end

      def drop(interface:, peer:)
        @lock.synchronize { @client.drop(interface: interface, peer: peer) }
        self
      end

      def running? = @thread&.alive? || false

      # Polls the client once and hands on what it says. The thread calls
      # it; a test on a fake clock calls it instead, since no thread runs.
      def poll
        events = @lock.synchronize { @client.poll(@loop.clock.now) }
        @sink.call(events) unless events.empty?
        events
      end

      # Stops the thread and closes the connections. Sessions stay in
      # bfdd4r unless already let go: Core::Bfd drops each one as its
      # neighbor goes Down when the router stops.
      def stop
        @stop = true
        @thread&.join(2)
        @thread = nil
        @lock.synchronize { @client.close }
        self
      end

      private

      # No thread on a fake clock: the test drives poll.
      def start
        return if running? || @stop || @loop.clock.fake?
        @thread = Thread.new do
          Thread.current.name = 'ospfd-bfd'
          Thread.current.report_on_exception = true
          run
        end
      end

      def run
        until @stop
          ios = @lock.synchronize { @client.ios }
          begin
            ios.empty? ? sleep(WAIT) : IO.select(ios, nil, nil, WAIT)
          rescue IOError
            # A socket closed under us: poll sees it and reconnects.
          end
          poll
        end
      rescue StandardError => e
        warn "ospfd: BFD thread: #{e.class}: #{e.message}"
        sleep(1)
        retry unless @stop
      end
    end
  end
end
