# frozen_string_literal: true

require 'socket'
require 'json'
require 'uri'
require 'time'

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

      # The API's version, raised when a route changes in a way an older
      # client cannot read (as ospfd's Api::VERSION).
      API_VERSION = 1

      # At most this many event streams at once; one more gets 503.
      MAX_STREAMS = 8

      # Seconds between two keepalive lines on a quiet stream (ospfd's
      # Api::KEEPALIVE).
      KEEPALIVE = 15

      # [method, path] => handler(server, query, body). One table for call
      # and for GET /api/info, so the list of routes cannot drift from what
      # is served. The link routes take an id and are listed by pattern.
      ROUTES = {
        %w[GET /] => ->(s, _q, _b) { [200, 'text/html; charset=utf-8', File.read(INDEX)] },
        %w[GET /index.html] => ->(s, _q, _b) { [200, 'text/html; charset=utf-8', File.read(INDEX)] },
        %w[GET /api/info] => ->(s, _q, _b) { s.send(:json, 200, s.info) },
        %w[GET /api/state] => ->(s, _q, _b) { s.send(:json, 200, s.sim.snapshot) },
        %w[GET /api/lsdb] => ->(s, q, _b) { s.send(:json, 200, s.sim.lsdb_rows(detail: q['detail'] == '1')) },
        %w[GET /api/lsdb.txt] => lambda do |s, q, _b|
          fmt = %w[junos ios plain].include?(q['format']) ? q['format'] : 'junos'
          [200, 'text/plain; charset=utf-8', s.sim.lsdb_text(fmt, verbose: q['verbose'] == '1')]
        end,
        %w[GET /api/lsa] => lambda do |s, q, _b|
          lsa = s.sim.lsa(q['type'] || 'router', q['id'], q['advr'] || q['id'])
          lsa ? [200, 'text/plain; charset=utf-8', lsa.to_s_junos_verbose] : s.send(:json, 404, error: 'no such LSA')
        end,
        %w[GET /api/events] => ->(s, q, _b) { s.send(:json, 200, s.sim.events(since: q['since'].to_i).map(&:to_h)) },
        # Served by #stream on a socket; call answers how to use it.
        %w[GET /api/events/stream] => ->(s, _q, _b) { s.send(:json, 400, error: 'a stream: open it over HTTP') },
        %w[GET /api/topology] => ->(s, _q, _b) { s.send(:json, 200, s.sim.topology.to_h) },
        %w[POST /api/refresh] => ->(s, _q, _b) { s.send(:json, 200, refreshed: s.sim.refresh_all.size) },
        %w[POST /api/flush] => lambda do |s, _q, _b|
          s.sim.flush_all
          s.send(:json, 200, ok: true)
        end,
        %w[POST /api/aging] => lambda do |s, _q, b|
          s.sim.aging = s.send(:body, b)['on'] ? true : false
          s.send(:json, 200, aging: s.sim.aging?)
        end,
        %w[POST /api/min-ls-interval] => lambda do |s, _q, b|
          p = s.send(:body, b)
          raise ArgumentError, 'seconds is required, from 0 to 5' unless p.key?('seconds')
          s.sim.min_ls_interval = p['seconds']
          s.send(:json, 200, min_ls_interval: s.sim.min_ls_interval)
        end,
        %w[POST /api/lsa/refresh] => ->(s, _q, b) { s.send(:lsa_action, :lsa_refresh, b) },
        %w[POST /api/lsa/flush] => ->(s, _q, b) { s.send(:lsa_action, :lsa_flush, b) },
        %w[POST /api/routes/withdraw] => ->(s, _q, b) { s.send(:route_action, :routes_withdraw, b) },
        %w[POST /api/routes/advertise] => ->(s, _q, b) { s.send(:route_action, :routes_advertise, b) },
        # OSPFv2::Fault, docs/design/sr-ospf.md step 0.
        %w[GET /api/faults] => ->(s, _q, _b) { s.send(:json, 200, s.sim.faults) },
        %w[POST /api/fault] => lambda do |s, _q, b|
          p = s.send(:body, b)
          raise ArgumentError, "case is required, one of #{OSPFv2::Fault.names.join(', ')}" unless p['case']
          s.send(:json, 200, s.sim.fault(p['case'], router: p['router']))
        end,
        %w[POST /api/fault/clear] => ->(s, _q, _b) { s.send(:json, 200, s.sim.fault_clear) },
        %w[POST /api/neighbor/start] => lambda do |s, _q, _b|
          s.sim.start unless s.sim.running?
          s.send(:json, 200, running: s.sim.running?)
        end,
        %w[POST /api/neighbor/stop] => lambda do |s, _q, _b|
          s.sim.stop if s.sim.running?
          s.send(:json, 200, running: s.sim.running?)
        end
      }.freeze

      LINK_ROUTE = %r{\A/api/links/(\d+)/(up|down|toggle|flap|metric)\z}
      LINK_ROUTES = %w[up down toggle flap metric].map { "POST /api/links/:id/#{_1}" }.freeze

      attr_reader :sim

      # What GET /api/info answers: who this is and every route it serves.
      def info
        { daemon: 'ospfv2-sim', version: OSPFv2::VERSION, api: API_VERSION,
          routes: ROUTES.keys.map { _1.join(' ') } + LINK_ROUTES }
      end

      # Routes a request; also used directly by the tests.
      # Returns [status, content_type, body].
      def call(method, path, query = {}, body = '', headers = {})
        if method == 'POST' && headers['x-ospfv2'].nil?
          return json(403, error: 'missing X-OSPFv2 header')
        end

        if (h = ROUTES[[method, path]])
          h.call(self, query, body)
        elsif method == 'POST' && (m = path.match(LINK_ROUTE))
          link_action(m[1].to_i, m[2], body)
        else
          json(404, error: "no route for #{method} #{path}")
        end
      rescue ArgumentError, JSON::ParserError => e
        json(400, error: e.message)
      rescue Simulator::NotFound => e
        json(404, error: e.message)
      rescue PermissionError => e
        json(409, error: e.message)
      end

      # GET /api/events/stream?since=N on +io+: one JSON object a line, in
      # the shapes of ospfd's events.subscribe. First the result line, then
      # each event after +since+ as it happens, and a keepalive line after
      # +keepalive+ quiet seconds. Ends when the client goes. Returns false,
      # writing nothing, when MAX_STREAMS are open already.
      def stream(io, since: 0, keepalive: KEEPALIVE)
        @streams_lock ||= Mutex.new
        @streams_lock.synchronize do
          return false if (@streams ||= 0) >= MAX_STREAMS
          @streams += 1
        end
        begin
          old = @sim.events(since: since)
          seq = @sim.event_seq
          io.write "#{JSON.generate(result: { seq: seq, replayed: old.size })}\n"
          old.each { |e| io.write line(e) }
          since = old.last ? old.last.seq : since
          quiet = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          loop do
            fresh = @sim.wait_events(since: since, timeout: 1)
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if fresh.empty?
              next unless now - quiet >= keepalive
              io.write "#{JSON.generate(keepalive: Time.now.utc.iso8601(3), seq: since)}\n"
            else
              fresh.each { |e| io.write line(e) }
              since = fresh.last.seq
            end
            quiet = now
          end
        rescue IOError, SystemCallError
          true # the client went
        ensure
          @streams_lock.synchronize { @streams -= 1 }
        end
      end

      # One event in ospfd's stream shape.
      def line(e)
        "#{JSON.generate(event: { seq: e.seq, time: e.at, level: 'info', kind: e.kind, message: e.text,
                                  data: e.data || {} })}\n"
      end

      private

      def body(b) = JSON.parse(b.to_s.empty? ? '{}' : b)

      def lsa_action(name, b)
        p = body(b)
        json(200, @sim.public_send(name, p['type'], p['id'], p['advr'] || p['id']))
      end

      def route_action(name, b)
        p = body(b)
        raise ArgumentError, 'router and prefix are required' if p['router'].to_s.empty? || p['prefix'].to_s.empty?
        json(200, @sim.public_send(name, p['router'], p['prefix']))
      end

      def link_action(id, action, body)
        l = case action
            when 'up' then @sim.link_up(id)
            when 'down' then @sim.link_down(id)
            when 'toggle' then @sim.toggle_link(id)
            when 'flap'
              p = JSON.parse(body.empty? ? '{}' : body)
              @sim.flap(id, count: (p['count'] || 3).to_i.clamp(1, 1000), interval: (p['interval'] || 5).to_f.clamp(0.5, 3600))
            when 'metric'
              @sim.set_metric(id, JSON.parse(body.empty? ? '{}' : body).fetch('metric') { raise ArgumentError, 'metric is required' })
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
        if method.to_s.upcase == 'GET' && uri.path == '/api/events/stream'
          return open_stream(sock, query['since'].to_i)
        end
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
                  409 => 'Conflict', 413 => 'Payload Too Large', 500 => 'Internal Server Error',
                  503 => 'Service Unavailable' }.freeze

      # The stream's head has no length: it ends when the connection does.
      def open_stream(sock, since)
        head = ->(status) {
          "HTTP/1.1 #{status} #{REASONS[status]}\r\nContent-Type: application/x-ndjson\r\n" \
            "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        }
        @streams_lock ||= Mutex.new
        full = @streams_lock.synchronize { (@streams ||= 0) >= MAX_STREAMS }
        return respond(sock, 503, 'application/json', JSON.generate(error: "#{MAX_STREAMS} streams open already")) if full
        sock.write head.(200)
        stream(sock, since: since)
      end

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
