# frozen_string_literal: true

require 'etc'
require 'io/wait'
require 'json'
require 'socket'
require 'fileutils'
require 'time'
require_relative 'events'
require_relative '../version'

module OSPFv2
  class Daemon
    # The management API: JSON lines over a Unix socket.
    #
    #   -> {"id": 1, "method": "show.neighbors", "params": {}}
    #   <- {"id": 1, "result": [...]}
    #   <- {"id": 1, "error": "unknown method show.foo"}
    #
    # events.subscribe turns the connection into a stream: after its reply,
    # one line per event, and a keepalive line when nothing happened for
    # KEEPALIVE seconds. events.unsubscribe ends the stream and the
    # connection takes requests again. Use another connection for requests
    # meanwhile.
    #
    #   -> {"id": 2, "method": "events.subscribe", "params": {"kinds": ["neighbor", "spf"], "since": 120}}
    #   <- {"id": 2, "result": {"seq": 131, "replayed": 11, "kinds": ["neighbor", "spf"]}}
    #   <- {"event": {"seq": 121, "time": "...", "level": "info", "kind": "neighbor", ...}}
    #   <- {"keepalive": "2026-10-28T03:18:31.004Z", "seq": 131}
    #   -> {"id": 3, "method": "events.unsubscribe"}
    #   <- {"id": 3, "result": {"unsubscribed": true}}
    #
    # The socket is created mode 0660, so access is by file permission:
    # root, and the socket's group if one is given.
    class Api
      MAX_LINE = 1 << 20   # bytes in one request
      MAX_CLIENTS = 32     # connections served at once
      IDLE = 900           # seconds a connection may sit silent
      KEEPALIVE = 15       # seconds between keepalive lines on an event stream
      VERSION = 1          # of this API: raised when a method changes in an incompatible way
      STREAM_METHODS = %w[events.subscribe events.unsubscribe].freeze

      # name => ->(daemon, params) { result }
      METHODS = {
        'show.overview' => ->(d, _) { d.views.overview },
        'show.neighbors' => ->(d, _) { d.views.neighbors },
        'show.interfaces' => ->(d, _) { d.views.interfaces },
        'show.database' => ->(d, p) { d.views.database(detail: p['detail'] == true) },
        'show.log' => ->(d, p) { d.views.log((p['count'] || 100).to_i.clamp(1, 2000)) },
        'show.statistics' => ->(d, _) { d.views.statistics },
        'show.routes' => ->(d, _) { d.views.routes },
        'show.fib' => ->(d, _) { d.views.fib },
        'show.spf' => ->(d, p) { d.views.spf((p['count'] || 100).to_i.clamp(1, 100)) },
        'show.configuration' => lambda do |d, p|
          d.show_configuration(candidate: p['candidate'] == true, format: p['format'] == 'set' ? :set : :curly)
        end,
        'config.load' => ->(d, p) { { errors: d.configure(Array(p['lines']).map(&:to_s)) } },
        # The whole candidate from set lines, like Junos "load override". A
        # bad text keeps the candidate as it was.
        'config.replace' => lambda do |d, p|
          d.load_override(Array(p['lines']).map(&:to_s).join("\n"))
          { errors: [] }
        rescue Config::Error => e
          { errors: [e.message] }
        end,
        'config.compare' => ->(d, _) { d.compare },
        'config.changed' => ->(d, _) { d.candidate_changed? },
        'config.commit' => ->(d, p) { d.commit(check: p['check'] == true, comment: p['comment']&.to_s) },
        'config.discard' => ->(d, _) { d.discard && nil },
        'config.rollback' => ->(d, p) { d.rollback(p['number'] || 0) },
        'config.history' => ->(d, _) { d.commit_history.map { |c| c.merge(time: c[:time].utc.iso8601) } },
        'clear.neighbors' => ->(d, p) { { cleared: d.clear_neighbors(p['router_id']) } },
        'api.info' => lambda do |d, _|
          { version: OSPFv2::VERSION, api: VERSION, methods: (METHODS.keys + STREAM_METHODS).sort,
            event_kinds: Events::KINDS, event_seq: d.events.seq }
        end
      }.freeze

      attr_reader :path

      def initialize(daemon, path:, group: nil, logger: nil, keepalive: KEEPALIVE)
        @daemon = daemon
        @keepalive = keepalive
        @path = path
        @group = group
        @logger = logger
        @clients = []
        @clients_lock = Mutex.new
      end

      # Raised when another ospfd already answers on the socket path.
      class InUse < StandardError; end

      def start
        FileUtils.mkdir_p(File.dirname(@path))
        if File.socket?(@path)
          raise InUse, "another ospfd is running on #{@path}" if live?(@path)
          File.delete(@path) # left by a daemon that died
        end
        gid = @group && Etc.getgrnam(@group).gid
        # The socket is born 0660: no window where umask leaves it open.
        old = File.umask(0o117)
        begin
          @server = UNIXServer.new(@path)
        ensure
          File.umask(old)
        end
        File.chown(nil, gid, @path) if gid
        @thread = Thread.new do
          Thread.current.name = 'ospfd-api'
          accept_loop
        end
        self
      end

      def stop
        @server&.close
        @thread&.join(2)
        @clients_lock.synchronize { @clients.dup }.each { |c| c.close unless c.closed? }
        File.delete(@path) if File.socket?(@path)
        self
      end

      # Handles one request Hash and returns the response Hash. Used by the
      # socket threads and directly by tests.
      def handle(req)
        id = req['id']
        name = req['method'].to_s
        fn = METHODS[name] or return { id: id, error: "unknown method #{name}" }
        params = req['params'].is_a?(Hash) ? req['params'] : {}
        { id: id, result: fn.call(@daemon, params) }
      rescue Config::Error, ArgumentError => e
        { id: id, error: e.message }
      rescue EventLoop::Stalled => e
        { id: id, error: "router busy: #{e.message}" }
      rescue StandardError => e
        @logger&.call(:error, "api #{name}: #{e.class}: #{e.message}")
        { id: id, error: "internal error: #{e.class}" }
      end

      private

      def live?(path)
        UNIXSocket.new(path).close
        true
      rescue SystemCallError
        false
      end

      def accept_loop
        loop do
          begin
            client = @server.accept
          rescue Errno::EMFILE, Errno::ENFILE, Errno::ENOBUFS, Errno::ENOMEM => e
            # Out of file descriptors: wait for some to free up, keep serving.
            @logger&.call(:warn, "api: #{e.message}")
            sleep 0.5
            next
          end
          busy = @clients_lock.synchronize do
            @clients.size >= MAX_CLIENTS || (@clients << client && false)
          end
          if busy
            reject(client, "too many connections (#{MAX_CLIENTS})")
            next
          end
          Thread.new(client) do |c|
            Thread.current.name = 'ospfd-api-client'
            serve(c)
          ensure
            @clients_lock.synchronize { @clients.delete(c) }
            c.close unless c.closed?
          end
        end
      rescue IOError, Errno::EBADF
        # server closed by #stop
      end

      # Closing a socket with unread input makes the kernel send a reset,
      # which can overtake our last reply. Half-close, then read and
      # discard what is left for a moment, then close.
      def close_gently(sock, max_bytes: 4 * MAX_LINE, max_wait: 1.0)
        sock.close_write
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + max_wait
        drained = 0
        while drained < max_bytes
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break unless left.positive? && sock.wait_readable(left)
          chunk = sock.read_nonblock(65_536, exception: false)
          break if chunk.nil? || chunk == :wait_readable
          drained += chunk.bytesize
        end
      rescue SystemCallError, IOError
        nil
      end

      def reject(client, why)
        client.write_nonblock("#{JSON.generate(error: why)}\n", exception: false)
        client.close
      rescue SystemCallError, IOError
        nil
      end

      def serve(sock)
        while sock.wait_readable(IDLE) && (line = sock.gets(MAX_LINE))
          unless line.end_with?("\n") || line.bytesize < MAX_LINE
            sock.write("#{JSON.generate(error: "request longer than #{MAX_LINE} bytes")}\n")
            close_gently(sock)
            return
          end
          req = begin
            JSON.parse(line)
          rescue JSON::ParserError => e
            sock.write("#{JSON.generate(error: "bad JSON: #{e.message[0, 80]}")}\n")
            next
          end
          unless req.is_a?(Hash)
            sock.write("#{JSON.generate(error: 'request must be a JSON object')}\n")
            next
          end
          case req['method']
          when 'events.subscribe' then return unless stream(sock, req)
          when 'events.unsubscribe' then sock.write("#{JSON.generate(id: req['id'], error: 'not subscribed')}\n")
          else sock.write("#{JSON.generate(handle(req))}\n")
          end
        end
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
        nil
      end

      # Streams events until the client unsubscribes (returns true: the
      # connection takes requests again) or goes away (returns false).
      def stream(sock, req)
        params = req['params'].is_a?(Hash) ? req['params'] : {}
        kinds = params['kinds'] && Array(params['kinds']).map(&:to_s)
        since = params['since'] && Integer(params['since'])
        sub, replayed = @daemon.events.subscribe(kinds: kinds, since: since)
        sock.write("#{JSON.generate(id: req['id'], result: { seq: @daemon.events.seq, replayed: replayed, kinds: kinds })}\n")
        buffer = +''
        last_write = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        loop do
          if sock.wait_readable(0)
            chunk = sock.read_nonblock(4096, exception: false)
            return false if chunk.nil? # client gone
            buffer << chunk unless chunk == :wait_readable
            return false if buffer.bytesize > MAX_LINE
            while (i = buffer.index("\n"))
              line = buffer.slice!(0..i)
              msg = (JSON.parse(line) rescue nil)
              if msg.is_a?(Hash) && msg['method'] == 'events.unsubscribe'
                sock.write("#{JSON.generate(id: msg['id'], result: { unsubscribed: true })}\n")
                return true
              end
              err = { id: msg.is_a?(Hash) ? msg['id'] : nil, error: 'streaming events: only events.unsubscribe, or use another connection' }
              sock.write("#{JSON.generate(err)}\n")
            end
          end
          ev = sub.pop(timeout: 0.2)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if ev
            sock.write("#{JSON.generate(event: ev)}\n")
            last_write = now
          elsif now - last_write >= @keepalive
            sock.write("#{JSON.generate(keepalive: Time.now.utc.iso8601(3), seq: @daemon.events.seq)}\n")
            last_write = now
          end
        end
      rescue ArgumentError, TypeError => e
        sock.write("#{JSON.generate(id: req['id'], error: e.message)}\n")
        true
      ensure
        sub&.close
      end
    end
  end
end
