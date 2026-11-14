# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'json'
require 'set'
require 'ospfv2/daemon'
require 'ospfv2/daemon/api'
require_relative '../../support/routescope_vocabulary'

# What routescope reads from ospfd (test/support/routescope_vocabulary.rb)
# is what ospfd answers. A change here that removes or renames a key
# routescope reads fails this test, before routescope sees it (routescope
# docs/design/api-contract.md, part 3).
#
# The daemon runs on a fake clock with a core peer on an in-memory segment,
# as daemon_test.rb has it, so every list routescope reads from has rows:
# a neighbor, LSAs, routes, FIB entries, an external, SPF runs, commits.
class TestRoutescopeVocabulary < Test::Unit::TestCase
  include OSPFv2

  A = ->(s) { Core::Addr.to_i(s) }

  BASE = ['set routing-options router-id 1.1.1.1',
          'set protocols ospf area 0 interface eth1',
          'set protocols ospf area 0 interface lo passive',
          'set policy-options policy-statement EXP term statics from protocol static',
          'set policy-options policy-statement EXP term statics then accept',
          'set protocols ospf export EXP'].freeze

  def setup
    @dir = Dir.mktmpdir('ospfd-vocabulary')
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e })
    hub = Transport::Hub.new
    system = Daemon::FakeSystem.new
    system.set('eth1', '10.0.0.1/24')
    system.set('lo', '1.1.1.1/32')
    system.statics = [[A['198.18.0.0'], 15]]
    @peer = Core::Instance.new(router_id: '2.2.2.2', loop: @loop)
    @peer.add_interface(name: 'e0', address: '10.0.0.2/24', transport: Transport::Loopback.new(hub, '10.0.0.2'))
    @peer.add_interface(name: 'lo', address: '2.2.2.2/32', passive: true,
                        transport: Transport::Loopback.new(Transport::Hub.new, '2.2.2.2'))
    @peer.start
    @daemon = Daemon.new(config_path: File.join(@dir, 'ospfd.conf'), loop: @loop, system: system,
                         transport: ->(_n, ip) { Transport::Loopback.new(hub, ip) })
    @daemon.start
    assert_empty @daemon.configure(BASE)
    assert @daemon.commit(comment: 'first')[:ok]
    assert @loop.run_until(120) { @peer.neighbors.first&.full? && @peer.routes.key?([A['198.18.0.0'], 15]) }
    @loop.advance(10) # SPF, the FIB, the last acks
    @api = Daemon::Api.new(@daemon, path: File.join(@dir, 's', 'ospfd.sock'))
  end

  def teardown
    @api.stop
    FileUtils.remove_entry(@dir)
  end

  # The answer as routescope gets it: JSON, so string keys.
  def call(method, params = {})
    r = @api.handle('id' => 1, 'method' => method, 'params' => params)
    assert_nil r[:error], "#{method} #{params}: #{r[:error]}"
    JSON.parse(JSON.generate(r[:result]))
  end

  # Every key path in an answer, in the vocabulary's syntax. A key is there
  # when any element of its array has it: rows differ by kind (a network
  # node has no abr flag), and routescope reads what is there.
  def paths(obj, prefix = '', out = Set.new)
    case obj
    when Hash
      obj.each do |k, v|
        out << "#{prefix}#{k}"
        paths(v, "#{prefix}#{k}.", out)
      end
    when Array then obj.each { |e| paths(e, "#{prefix.delete_suffix('.')}[].", out) }
    end
    out
  end

  # Each method, with the calls routescope makes of it. A method answered
  # in two shapes (show.topology for an area, or the AS) has a key when
  # either answer has it.
  def calls
    {
      'show.overview' => [{}], 'show.neighbors' => [{}], 'show.interfaces' => [{}],
      'show.database' => [{}, { 'detail' => true }], 'show.routes' => [{}], 'show.fib' => [{}],
      'show.spf' => [{}], 'show.timers' => [{}],
      'show.topology' => [{ 'area' => '0' }, { 'scope' => 'as' }],
      'show.configuration' => [{ 'format' => 'set' }],
      'config.changed' => [{}],
      'config.replace' => [{ 'lines' => BASE + ['set protocols ospf area 0 interface eth1 metric 5'] }],
      'config.compare' => [{}],
      'config.commit' => [{ 'check' => true }, { 'comment' => 'second' }],
      'config.history' => [{}],
      'config.rollback' => [{ 'number' => 1 }],
      'config.discard' => [{}]
    }
  end

  def test_ospfd_answers_every_key_routescope_reads
    answered = calls.to_h { |m, ps| [m, ps.map { |p| call(m, p) }] }
    missing = RoutescopeVocabulary::OSPFD.flat_map do |m, keys|
      next [] if m == 'events.subscribe' # a stream; the next test checks it
      have = answered.fetch(m) { flunk "#{m}: routescope reads it and this test does not call it" }
                     .reduce(Set.new) { |s, a| s | paths(a) }
      keys.reject { have.include?(_1) }.map { "#{m} #{_1}" }
    end
    assert_equal [], missing, 'keys routescope reads that ospfd does not answer'
  end

  # The methods are what api.info lists, so routescope's own check
  # (its contract_test.rb) and this one agree.
  def test_api_info_lists_every_method_routescope_calls
    listed = call('api.info')['methods']
    assert_equal [], RoutescopeVocabulary::OSPFD.keys - listed
  end
end
