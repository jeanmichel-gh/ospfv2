# frozen_string_literal: true

require 'socket'
require 'json'
require 'uri'

module OSPFv2
  module Web
    # A small HTTP/1.1 server for the dashboard and its JSON API, built on
    # the standard library only. Binds 127.0.0.1 unless told otherwise.
    #
    # Mutating endpoints are POST and require the X-OSPFv2 header, which a
    # cross-site form cannot set, so another tab cannot flap your links.
    class Server
      INDEX = File.join(__dir__, 'index.html')
      MAX_BODY = 64 * 1024

      attr_reader :port, :host

      def initialize(sim, host: '127.0.0.1', port: 8080)
        @sim = sim
        @host = host
        @port = port
      end

      def start
        @server = TCPServer.new(@host, @port)
        @port = @server.addr[1]
        @thread = Thread.new do
          Thread.current.name = 'ospfv2-web'
          loop do
            client = @server.accept
            Thread.new(client) { |c| handle(c) }
          rescue IOError, Errno::EBADF
            break
          end
        end
        self
      end

      def stop
        @server&.close
        @thread&.kill
      end

      # Routes a request; also used directly by the tests.
      # Returns [status, content_type, body].
      def call(method, path, query = {}, body = '', headers = {})
        if method == 'POST' && headers['x-ospfv2'].nil?
          return json(403, error: 'missing X-OSPFv2 header')
        end

        case [method, path]
        when %w[GET /], %w[GET /index.html]
          [200, 'text/html; charset=utf-8', File.read(INDEX)]
        when %w[GET /api/state]
          json(200, @sim.snapshot)
        when %w[GET /api/lsdb]
          json(200, @sim.lsdb_rows)
        when %w[GET /api/lsdb.txt]
          fmt = %w[junos ios plain].include?(query['format']) ? query['format'] : 'junos'
          [200, 'text/plain; charset=utf-8', @sim.lsdb_text(fmt, verbose: query['verbose'] == '1')]
        when %w[GET /api/lsa]
          lsa = @sim.lsa(query['type'] || 'router', query['id'], query['advr'] || query['id'])
          lsa ? [200, 'text/plain; charset=utf-8', lsa.to_s_junos_verbose] : json(404, error: 'no such LSA')
        when %w[GET /api/events]
          json(200, @sim.events(since: query['since'].to_i).map(&:to_h))
        when %w[GET /api/topology]
          json(200, @sim.topology.to_h)
        when %w[POST /api/refresh]
          json(200, refreshed: @sim.refresh_all.size)
        when %w[POST /api/flush]
          @sim.flush_all
          json(200, ok: true)
        when %w[POST /api/aging]
          @sim.aging = JSON.parse(body.empty? ? '{}' : body)['on'] ? true : false
          json(200, aging: @sim.aging?)
        when %w[POST /api/neighbor/start]
          @sim.start unless @sim.running?
          json(200, running: @sim.running?)
        when %w[POST /api/neighbor/stop]
          @sim.stop if @sim.running?
          json(200, running: @sim.running?)
        else
          if method == 'POST' && (m = path.match(%r{\A/api/links/(\d+)/(up|down|toggle|flap)\z}))
            link_action(m[1].to_i, m[2], body)
          else
            json(404, error: "no route for #{method} #{path}")
          end
        end
      rescue ArgumentError, JSON::ParserError => e
        json(400, error: e.message)
      rescue PermissionError => e
        json(409, error: e.message)
      end

      private

      def link_action(id, action, body)
        l = case action
            when 'up' then @sim.link_up(id)
            when 'down' then @sim.link_down(id)
            when 'toggle' then @sim.toggle_link(id)
            when 'flap'
              p = JSON.parse(body.empty? ? '{}' : body)
              @sim.flap(id, count: (p['count'] || 3).to_i.clamp(1, 1000), interval: (p['interval'] || 5).to_f.clamp(0.5, 3600))
            end
        json(200, l.to_h)
      end

      def json(status, obj)
        [status, 'application/json', JSON.generate(obj)]
      end

      def handle(sock)
        sock.sync = true
        line = sock.gets("\r\n", 8192) or return
        method, target, = line.split(' ', 3)
        headers = {}
        while (h = sock.gets("\r\n", 8192)) && h != "\r\n"
          k, v = h.split(':', 2)
          headers[k.strip.downcase] = v.to_s.strip if v
        end
        len = headers['content-length'].to_i
        return respond(sock, 413, 'text/plain', 'too large') if len > MAX_BODY
        body = len.positive? ? sock.read(len).to_s : ''
        uri = URI.parse(target.to_s)
        query = URI.decode_www_form(uri.query.to_s).to_h
        status, type, payload = call(method.to_s.upcase, uri.path, query, body, headers)
        respond(sock, status, type, payload)
      rescue URI::InvalidURIError
        respond(sock, 400, 'text/plain', 'bad request')
      rescue StandardError => e
        respond(sock, 500, 'text/plain', "#{e.class}: #{e.message}") rescue nil
      ensure
        sock.close rescue nil
      end

      REASONS = { 200 => 'OK', 400 => 'Bad Request', 403 => 'Forbidden', 404 => 'Not Found',
                  409 => 'Conflict', 413 => 'Payload Too Large', 500 => 'Internal Server Error' }.freeze

      def respond(sock, status, type, body)
        body = body.to_s.b
        sock.write "HTTP/1.1 #{status} #{REASONS[status] || 'OK'}\r\n" \
                   "Content-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n" \
                   "Connection: close\r\n\r\n"
        sock.write body
      end
    end
  end
end
