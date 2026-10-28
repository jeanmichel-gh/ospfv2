# frozen_string_literal: true

require 'json'
require 'socket'

module OSPFv2
  module CommandLine
    class Error < StandardError; end

    # Talks to ospfd's management API over its Unix socket.
    class Client
      DEFAULT_SOCKET = '/run/ospfv2/ospfd.sock'

      def initialize(path = ENV.fetch('OSPFV2_SOCKET', DEFAULT_SOCKET))
        @path = path
        @id = 0
      end

      # Returns the result, or raises CommandLine::Error with the daemon's message.
      def call(method, params = {})
        connect
        @id += 1
        @sock.write("#{JSON.generate(id: @id, method: method, params: params)}\n")
        line = @sock.gets or raise Error, 'ospfd closed the connection'
        resp = JSON.parse(line)
        raise Error, resp['error'] if resp['error']
        resp['result']
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        @sock = nil
        raise Error, 'lost the connection to ospfd'
      end

      def close
        @sock&.close
        @sock = nil
      end

      # Streams events on a connection of its own: yields each event Hash
      # until the block returns :stop, ospfd closes the stream, or the
      # caller is interrupted. Keepalives are not yielded.
      def subscribe(kinds: nil, since: nil)
        sock = open_socket
        params = {}
        params[:kinds] = kinds if kinds && !kinds.empty?
        params[:since] = since if since
        sock.write("#{JSON.generate(id: 1, method: 'events.subscribe', params: params)}\n")
        first = sock.gets or raise Error, 'ospfd closed the connection'
        resp = JSON.parse(first)
        raise Error, resp['error'] if resp['error']
        while (line = sock.gets)
          msg = JSON.parse(line)
          next unless msg['event']
          break if yield(msg['event']) == :stop
        end
        resp['result']
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        raise Error, 'lost the connection to ospfd'
      ensure
        sock&.close
      end

      private

      def open_socket
        UNIXSocket.new(@path)
      rescue Errno::ENOENT, Errno::ECONNREFUSED
        raise Error, "cannot reach ospfd at #{@path}: is it running?"
      rescue Errno::EACCES
        raise Error, "permission denied on #{@path}: run as root or a member of its group"
      end

      def connect
        @sock ||= UNIXSocket.new(@path)
      rescue Errno::ENOENT, Errno::ECONNREFUSED
        raise Error, "cannot reach ospfd at #{@path}: is it running?"
      rescue Errno::EACCES
        raise Error, "permission denied on #{@path}: run as root or a member of its group"
      end
    end

    # Calls a Daemon::Api in the same process. Used by tests and the demo.
    class LocalClient
      def initialize(api)
        @api = api
      end

      def call(method, params = {})
        resp = JSON.parse(JSON.generate(@api.handle('method' => method, 'params' => JSON.parse(JSON.generate(params)))))
        raise Error, resp['error'] if resp['error']
        resp['result']
      end

      def close; end

      def subscribe(**)
        raise Error, 'monitor needs ospfd over its socket'
      end
    end
  end
end
