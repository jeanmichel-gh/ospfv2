# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'ospfv2/daemon'
require 'ospfv2/daemon/api'
require 'ospfv2/command_line/client'

class TestDaemonApi < Test::Unit::TestCase
  include OSPFv2

  def setup
    @dir = Dir.mktmpdir('ospfd-api')
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e })
    system = Daemon::FakeSystem.new
    system.set('lo', '1.1.1.1/32')
    @daemon = Daemon.new(config_path: File.join(@dir, 'ospfd.conf'), loop: @loop, system: system)
    @daemon.start
    @api = Daemon::Api.new(@daemon, path: File.join(@dir, 's', 'ospfd.sock'))
  end

  def teardown
    @api.stop
    FileUtils.remove_entry(@dir)
  end

  def call(method, params = {})
    @api.handle('id' => 1, 'method' => method, 'params' => params)
  end

  def test_configure_commit_and_show
    r = call('config.load', 'lines' => ['set routing-options router-id 1.1.1.1',
                                         'set protocols ospf area 0 interface lo passive'])
    assert_equal({ errors: [] }, r[:result])
    assert_equal true, call('config.changed')[:result]
    c = call('config.commit', 'comment' => 'first')[:result]
    assert c[:ok]
    assert_equal false, call('config.changed')[:result]
    assert_equal '1.1.1.1', call('show.overview')[:result][:router_id]
    assert_equal ['lo'], call('show.interfaces')[:result].map { |i| i[:name] }
    assert_match(/passive;/, call('show.configuration')[:result])
    assert_match(/\Aset routing-options/, call('show.configuration', 'format' => 'set')[:result])
    assert_equal 'first', call('config.history')[:result].first[:comment]
  end

  def test_replace_the_whole_candidate
    call('config.load', 'lines' => ['set routing-options router-id 1.1.1.1', 'set protocols ospf area 0 interface lo passive'])
    assert call('config.commit', 'comment' => 'first')[:result][:ok]
    r = call('config.replace', 'lines' => ['# a saved file', 'set routing-options router-id 2.2.2.2'])
    assert_equal({ errors: [] }, r[:result])
    assert_equal ['- set protocols ospf area 0.0.0.0 interface lo passive', '- set routing-options router-id 1.1.1.1',
                  '+ set routing-options router-id 2.2.2.2'].sort, call('config.compare')[:result].sort
    bad = call('config.replace', 'lines' => ['set nonsense'])[:result][:errors]
    assert_match(/nonsense/, bad.first)
    assert_equal 3, call('config.compare')[:result].size, 'a bad text keeps the candidate'
    assert_includes call('api.info')[:result][:methods], 'config.replace'
  end

  def test_errors_come_back_as_messages
    assert_equal 'unknown method show.secrets', call('show.secrets')[:error]
    assert_match(/line 1: .*unknown 'bogus'/, call('config.load', 'lines' => ['set bogus'])[:result][:errors].first)
    assert_match(/rollback must be 0\.\.9/, call('config.rollback', 'number' => 42)[:error])
    r = call('config.commit')[:result]
    assert_equal false, r[:ok]
    assert_match(/router-id is required/, r[:errors].first)
  end

  def test_over_the_socket
    @loop2 = nil
    @api.start
    assert_equal 0o660, File.stat(@api.path).mode & 0o777
    client = CommandLine::Client.new(@api.path)
    # The fake-clock loop is not running, so calls run inline on the
    # socket thread.
    assert_equal({ 'errors' => [] }, client.call('config.load', lines: ['set routing-options router-id 3.3.3.3']))
    assert_equal true, client.call('config.changed')
    e = assert_raise(CommandLine::Error) { client.call('nope') }
    assert_match(/unknown method nope/, e.message)

    raw = UNIXSocket.new(@api.path)
    raw.write("not json\n")
    assert_match(/bad JSON/, JSON.parse(raw.gets)['error'])
    raw.write("[1,2]\n")
    assert_match(/must be a JSON object/, JSON.parse(raw.gets)['error'])
    raw.close
    client.close
  end

  def test_socket_rules
    old = File.umask(0)
    begin
      @api.start
    ensure
      File.umask(old)
    end
    assert_equal 0o660, File.stat(@api.path).mode & 0o777, 'mode set at creation, whatever the umask'

    second = Daemon::Api.new(@daemon, path: @api.path)
    e = assert_raise(Daemon::Api::InUse) { second.start }
    assert_match(/another ospfd is running/, e.message)
    assert File.socket?(@api.path), 'the live socket is not stolen'

    @api.stop
    stale = UNIXServer.new(@api.path) # a socket nobody answers on once closed
    stale.close
    assert File.socket?(@api.path)
    third = Daemon::Api.new(@daemon, path: @api.path)
    assert_nothing_raised { third.start }
    third.stop
  end

  def test_oversized_request_is_refused
    @api.start
    s = UNIXSocket.new(@api.path)
    # Twice the limit: plenty left unread when the server answers.
    Thread.new { s.write('x' * (2 * Daemon::Api::MAX_LINE)) rescue nil }
    resp = JSON.parse(s.gets)
    assert_match(/longer than/, resp['error'])
    assert_nil s.gets, 'and the connection is closed'
    s.close
  end

  def test_too_many_clients_are_turned_away
    @api.start
    held = Array.new(Daemon::Api::MAX_CLIENTS) { UNIXSocket.new(@api.path) }
    sleep 0.2
    extra = UNIXSocket.new(@api.path)
    assert_match(/too many connections/, JSON.parse(extra.gets)['error'])
    extra.close
    held.first.close
    sleep 0.2
    again = CommandLine::Client.new(@api.path)
    assert_equal false, again.call('config.changed')
    again.close
    held.drop(1).each(&:close)
  end

  def test_client_reports_a_missing_daemon
    e = assert_raise(CommandLine::Error) { CommandLine::Client.new(File.join(@dir, 'none.sock')).call('show.overview') }
    assert_match(/cannot reach ospfd/, e.message)
  end

  def publish(msg, kind: :log)
    @daemon.events.publish(time: Time.now, level: :info, kind: kind, message: msg)
  end

  def read_json(sock) = JSON.parse(sock.gets)

  def test_api_info
    info = call('api.info')[:result]
    assert_equal OSPFv2::VERSION, info[:version]
    assert_equal Daemon::Api::VERSION, info[:api]
    assert_include info[:methods], 'events.subscribe'
    assert_include info[:methods], 'show.neighbors'
    assert_include info[:event_kinds], 'neighbor'
  end

  def test_event_stream_over_the_socket
    @api.stop
    @api = Daemon::Api.new(@daemon, path: @api.path, keepalive: 0.3)
    @api.start
    since = @daemon.events.seq # the daemon's own startup events come before
    publish('before')
    s = UNIXSocket.new(@api.path)
    s.write("#{JSON.generate(id: 7, method: 'events.subscribe', params: { since: since, kinds: %w[log spf] })}\n")
    r = read_json(s)
    assert_equal 7, r['id']
    assert_equal 1, r['result']['replayed']
    assert_equal %w[log spf], r['result']['kinds']
    assert_equal 'before', read_json(s)['event']['message'], 'replayed first'

    publish('ignored', kind: :neighbor)
    publish('live', kind: :spf)
    ev = read_json(s)['event']
    assert_equal %w[live spf], [ev['message'], ev['kind']]
    assert_kind_of Integer, ev['seq']

    ka = read_json(s)
    assert ka.key?('keepalive'), "expected a keepalive, got #{ka}"

    s.write("#{JSON.generate(id: 8, method: 'show.overview')}\n")
    assert_match(/only events.unsubscribe/, read_json(s)['error'])

    s.write("#{JSON.generate(id: 9, method: 'events.unsubscribe')}\n")
    line = read_json(s)
    line = read_json(s) while line.key?('keepalive') || line.key?('event')
    assert_equal({ 'id' => 9, 'result' => { 'unsubscribed' => true } }, line)
    sleep 0.05
    assert_equal 0, @daemon.events.subscribers
    s.write("#{JSON.generate(id: 10, method: 'config.changed')}\n")
    assert_equal false, read_json(s)['result'], 'back to requests'
    s.close
  end

  def test_stream_ends_when_the_client_goes
    @api.start
    s = UNIXSocket.new(@api.path)
    s.write("#{JSON.generate(id: 1, method: 'events.subscribe')}\n")
    read_json(s)
    assert_equal 1, @daemon.events.subscribers
    s.close
    deadline = Time.now + 2
    sleep 0.05 while @daemon.events.subscribers.positive? && Time.now < deadline
    assert_equal 0, @daemon.events.subscribers
  end

  def test_subscribe_errors
    @api.start
    s = UNIXSocket.new(@api.path)
    s.write("#{JSON.generate(id: 1, method: 'events.subscribe', params: { kinds: ['bogus'] })}\n")
    assert_match(/unknown event kind bogus/, read_json(s)['error'])
    s.write("#{JSON.generate(id: 2, method: 'events.unsubscribe')}\n")
    assert_equal 'not subscribed', read_json(s)['error']
    s.close
  end

  def test_client_subscribe
    @api.start
    client = CommandLine::Client.new(@api.path)
    got = []
    t = Thread.new do
      client.subscribe(kinds: %w[log]) { |ev| got << ev['message']; :stop if got.size == 2 }
    end
    sleep 0.02 until @daemon.events.subscribers == 1
    publish('a')
    publish('b')
    assert t.join(2), 'subscribe returns on :stop'
    assert_equal %w[a b], got
  end
end
