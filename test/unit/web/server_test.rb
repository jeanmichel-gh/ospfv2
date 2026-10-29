require 'test/unit'
require 'json'
require 'net/http'
require 'ospfv2/simulator'
require 'ospfv2/web/server'
require_relative '../../support/capture_transport'

class TestWebServer < Test::Unit::TestCase
  include OSPFv2

  def setup
    t = Topology.from_hash(grid: { columns: 3, rows: 2 })
    @sim = Simulator.new(t, transport: CaptureTransport.new)
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
end
