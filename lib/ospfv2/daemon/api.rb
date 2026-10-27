# frozen_string_literal: true

require 'etc'
require 'io/wait'
require 'json'
require 'socket'
require 'fileutils'

module OSPFv2
  class Daemon
    # The management API: JSON lines over a Unix socket.
    #
    #   -> {"id": 1, "method": "show.neighbors", "params": {}}
    #   <- {"id": 1, "result": [...]}
    #   <- {"id": 1, "error": "unknown method show.foo"}
    #
    # The socket is created mode 0660, so access is by file permission:
    # root, and the socket's group if one is given.
    class Api
      MAX_LINE = 1 << 20   # bytes in one request
      MAX_CLIENTS = 32     # connections served at once
      IDLE = 900           # seconds a connection may sit silent

      # name => ->(daemon, params) { result }
      METHODS = {
        'show.overview' => ->(d, _) { d.views.overview },
        'show.neighbors' => ->(d, _) { d.views.neighbors },
        'show.interfaces' => ->(d, _) { d.views.interfaces },
        'show.database' => ->(d, p) { d.views.database(detail: p['detail'] == true) },
        'show.log' => ->(d, p) { d.views.log((p['count'] || 100).to_i.clamp(1, 2000)) },
        'show.statistics' => ->(d, _) { d.views.statistics },
        'show.configuration' => lambda do |d, p|
          d.show_configuration(candidate: p['candidate'] == true, format: p['format'] == 'set' ? :set : :curly)
        end,
        'config.load' => ->(d, p) { { errors: d.configure(Array(p['lines']).map(&:to_s)) } },
        'config.compare' => ->(d, _) { d.compare },
        'config.changed' => ->(d, _) { d.candidate_changed? },
        'config.commit' => ->(d, p) { d.commit(check: p['check'] == true, comment: p['comment']&.to_s) },
        'config.discard' => ->(d, _) { d.discard && nil },
        'config.rollback' => ->(d, p) { d.rollback(p['number'] || 0) },
        'config.history' => ->(d, _) { d.commit_history.map { |c| c.merge(time: c[:time].utc.iso8601) } },
        'clear.neighbors' => ->(d, p) { { cleared: d.clear_neighbors(p['router_id']) } }
      }.freeze

      attr_reader :path

      def initialize(daemon, path:, group: nil, logger: nil)
        @daemon = daemon
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
            return
          end
          resp = begin
            req = JSON.parse(line)
            req.is_a?(Hash) ? handle(req) : { error: 'request must be a JSON object' }
          rescue JSON::ParserError => e
            { error: "bad JSON: #{e.message[0, 80]}" }
          end
          sock.write("#{JSON.generate(resp)}\n")
        end
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
        nil
      end
    end
  end
end
