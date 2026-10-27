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

  def test_client_reports_a_missing_daemon
    e = assert_raise(CommandLine::Error) { CommandLine::Client.new(File.join(@dir, 'none.sock')).call('show.overview') }
    assert_match(/cannot reach ospfd/, e.message)
  end
end
