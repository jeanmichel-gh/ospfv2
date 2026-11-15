require 'test/unit'
require 'json'
require 'net/http'
require 'socket'
require 'ospfv2/simulator'
require 'ospfv2/web/server'
require_relative '../../support/capture_transport'

class TestWebServer < Test::Unit::TestCase
  include OSPFv2

  def setup
    t = Topology.from_hash(grid: { columns: 3, rows: 2 })
    @sim = Simulator.new(t, transport: CaptureTransport.new, min_ls_interval: 0)
    @app = Web::Server.new(@sim, port: 0)
  end

  def get(path, query = {}) = @app.call('GET', path, query)
  def post(path, body = '') = @app.call('POST', path, {}, body, { 'x-ospfv2' => '1' })

  def test_index
    status, type, body = get('/')
    assert_equal 200, status
    assert_match %r{text/html}, type
    assert_match(/ospfv2 lab/, body)
  end

  def test_state
    status, _, body = get('/api/state')
    assert_equal 200, status
    s = JSON.parse(body)
    assert_equal 'down', s['neighbor']['state']
    assert_equal 8, s['links'].size
    assert_equal 7, s['counts']['router']
  end

  def test_lsdb_json_and_text
    rows = JSON.parse(get('/api/lsdb')[2])
    assert_equal @sim.ls_db.size, rows.size
    assert_match(/OSPF link state database/, get('/api/lsdb.txt', 'format' => 'junos')[2])
    status, _, body = get('/api/lsa', 'type' => 'router', 'id' => '0.1.0.1')
    assert_equal 200, status
    assert_match(/Router\s+0.1.0.1/, body)
    assert_equal 404, get('/api/lsa', 'type' => 'router', 'id' => '9.9.9.9')[0]
  end

  # detail=1: every body decoded, in the shape ospfd's API gives.
  def test_lsdb_detail
    refute JSON.parse(get('/api/lsdb')[2]).first.key?('detail')
    rows = JSON.parse(get('/api/lsdb', 'detail' => '1')[2])
    assert rows.all? { |r| r['detail'].is_a?(Hash) && !r['detail'].key?('error') }, rows.find { |r| r['detail'].nil? || r['detail']['error'] }.to_s
    r = rows.find { |x| x['type'] == 'router' && x['ls_id'] == '0.1.0.1' }
    assert_equal %w[b e v], r['detail']['flags'].keys
    assert(r['detail']['links'].all? { |l| %w[p2p transit stub virtual].include?(l['type']) && l['metric'].is_a?(Integer) })
    ext = rows.find { |x| x['type'] == 'as_external' }
    assert_equal [1, 2].include?(ext['detail']['external_type']), true if ext
  end

  def test_post_requires_header
    status, _, body = @app.call('POST', '/api/links/1/down', {}, '', {})
    assert_equal 403, status
    assert_match(/X-OSPFv2/, body)
    assert @sim.link(1).up?
  end

  def test_link_actions
    assert_equal false, JSON.parse(post('/api/links/1/down')[2])['up']
    assert_equal true, JSON.parse(post('/api/links/1/toggle')[2])['up']
    status, _, body = post('/api/links/99/down')
    assert_equal 400, status
    assert_match(/no such link/, body)
    assert_equal 25, JSON.parse(post('/api/links/1/metric', '{"metric":25}')[2])['metric']
    assert_equal 400, post('/api/links/1/metric', '{"metric":0}')[0]
    assert_equal 400, post('/api/links/1/metric', '{}')[0]
  end

  def test_events_since
    post('/api/links/2/down')
    all = JSON.parse(get('/api/events')[2])
    last = all.last['seq']
    assert_equal [], JSON.parse(get('/api/events', 'since' => last.to_s)[2])
    assert_match(/link r1c2--r1c3 down/, all.last['text'])
  end

  def test_aging_refresh_unknown
    assert_equal true, JSON.parse(post('/api/aging', '{"on":true}')[2])['aging']
    assert_equal false, JSON.parse(post('/api/aging', '{"on":false}')[2])['aging']
    assert_equal 400, post('/api/aging', '{bad')[0]
    assert JSON.parse(post('/api/refresh')[2])['refreshed'].positive?
    assert_equal 404, get('/nope')[0]
  end

  def test_real_http
    @app.start
    http = Net::HTTP.new('127.0.0.1', @app.port)
    res = http.get('/api/state')
    assert_equal '200', res.code
    assert_equal 'no-store', res['cache-control']
    req = Net::HTTP::Post.new('/api/links/3/down', 'X-OSPFv2' => '1', 'Content-Type' => 'application/json')
    req.body = '{}'
    assert_equal '200', http.request(req).code
    refute @sim.link(3).up?
  ensure
    @app.stop
  end
  # ---- one LSA, routes, MinLSInterval, info, stream (docs/design/sim-lsa-actions.md)

  def test_lsa_refresh_and_flush
    body = '{"type":"router","id":"0.1.0.1","advr":"0.1.0.1"}'
    seq = JSON.parse(post('/api/lsa/refresh', body)[2])['seq']
    row = JSON.parse(post('/api/lsa/flush', body)[2])
    assert_equal [seq, 3600, true], row.values_at('seq', 'age', 'flushed')
    assert_equal 404, post('/api/lsa/refresh', '{"type":"router","id":"9.9.9.9"}')[0]
    assert_equal 400, post('/api/lsa/refresh', '{"type":"bogus","id":"0.1.0.1"}')[0]
    assert_equal 400, post('/api/lsa/refresh', '{bad')[0]
    status, _, b = post('/api/lsa/flush', '{"type":"router","id":"1.1.1.1"}')
    assert_equal 409, status
    assert_match(/stop the neighbor/, b)
  end

  def test_routes_withdraw_and_advertise
    t = Topology.build do
      simulator router_id: '1.1.1.1', interface: '192.168.1.1/24'
      grid columns: 2, rows: 1
      router('edge', id: '10.0.0.1') { externals '50.0.0.0/24', metric: 20 }
      link 'r1c2', 'edge'
    end
    @sim = Simulator.new(t, transport: CaptureTransport.new, min_ls_interval: 0)
    @app = Web::Server.new(@sim, port: 0)
    row = JSON.parse(post('/api/routes/withdraw', '{"router":"edge","prefix":"50.0.0.0/24"}')[2])
    assert_equal %w[as_external 3600], [row['kind'], row['age'].to_s]
    assert_equal 0, JSON.parse(post('/api/routes/advertise', '{"router":"edge","prefix":"50.0.0.0/24"}')[2])['age']
    assert_equal 404, post('/api/routes/withdraw', '{"router":"edge","prefix":"60.0.0.0/24"}')[0]
    assert_equal 400, post('/api/routes/withdraw', '{"router":"edge"}')[0]
  end

  def test_min_ls_interval
    assert_equal 2.5, JSON.parse(post('/api/min-ls-interval', '{"seconds":2.5}')[2])['min_ls_interval']
    assert_equal 0.0, JSON.parse(post('/api/min-ls-interval', '{"seconds":0}')[2])['min_ls_interval']
    assert_equal 400, post('/api/min-ls-interval', '{"seconds":9}')[0]
    assert_equal 400, post('/api/min-ls-interval', '{}')[0]
  end

  def test_every_new_post_needs_the_header
    %w[/api/lsa/refresh /api/lsa/flush /api/routes/withdraw /api/routes/advertise /api/min-ls-interval].each do |path|
      assert_equal 403, @app.call('POST', path, {}, '{}', {})[0], path
    end
  end

  # Every route the info lists is served: none answers 404.
  def test_info_lists_every_route
    info = JSON.parse(get('/api/info')[2])
    assert_equal ['ospfv2-sim', OSPFv2::VERSION, 1], info.values_at('daemon', 'version', 'api')
    info['routes'].each do |r|
      method, path = r.split(' ', 2)
      path = path.sub(':id', '1')
      status = method == 'GET' ? get(path)[0] : post(path, '{}')[0]
      refute_equal 404, status, r
    end
    assert_includes info['routes'], 'GET /api/events/stream'
    assert_includes info['routes'], 'POST /api/links/:id/metric'
  end

  def test_events_carry_data_and_a_full_time
    post('/api/lsa/refresh', '{"type":"router","id":"0.1.0.1"}')
    e = JSON.parse(get('/api/events')[2]).last
    assert_match(/\A\d\d:\d\d:\d\d\z/, e['time'], 'time keeps its old shape')
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, e['at'])
    assert_equal 'router', e['data']['lsas'].first['type']
  end

  def stream_lines(since: 0, keepalive: 15)
    r, w = UNIXSocket.pair
    t = Thread.new { @app.stream(w, since: since, keepalive: keepalive) }
    yield r
  ensure
    r&.close
    t&.join(3)
    w&.close
  end

  def read_json(io) = JSON.parse(io.gets)

  def test_stream_replays_then_follows
    post('/api/links/1/down')
    stream_lines do |r|
      head = read_json(r)
      assert head['result']['replayed'].positive?
      replayed = Array.new(head['result']['replayed']) { read_json(r) }
      assert_match(/link .* down/, replayed.last['event']['message'])
      post('/api/links/1/up')
      ev = read_json(r)['event']
      assert_match(/link .* up/, ev['message'])
      assert_equal 'lsdb', ev['kind']
      assert_match(/Z\z/, ev['time'])
      assert ev['data']['lsas'].is_a?(Array)
    end
  end

  def test_stream_since_and_keepalive
    seq = @sim.event_seq
    stream_lines(since: seq, keepalive: 0.2) do |r|
      assert_equal 0, read_json(r)['result']['replayed']
      k = read_json(r)
      assert k.key?('keepalive')
      assert_equal seq, k['seq']
    end
  end

  def test_streams_are_capped
    pairs = Array.new(Web::Server::MAX_STREAMS) { UNIXSocket.pair }
    threads = pairs.map { |_, w| Thread.new { @app.stream(w) } }
    pairs.each { |r, _| r.gets }
    r, w = UNIXSocket.pair
    assert_equal false, @app.stream(w)
  ensure
    pairs&.each { |a, b| a.close; b.close rescue nil }
    threads&.each { _1.join(3) }
    [r, w].each { _1&.close rescue nil }
  end

  def test_stream_over_http
    @app.start
    sock = TCPSocket.new('127.0.0.1', @app.port)
    sock.write "GET /api/events/stream?since=0 HTTP/1.1\r\nHost: x\r\n\r\n"
    assert_match(%r{\AHTTP/1.1 200}, sock.gets)
    nil until sock.gets == "\r\n"
    assert JSON.parse(sock.gets).key?('result')
  ensure
    sock&.close
    @app.stop
  end
end
