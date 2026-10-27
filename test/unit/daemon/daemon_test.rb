# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'ospfv2/daemon'

# The daemon on a fake clock, with a fake host and a core peer on an
# in-memory segment.
class TestDaemon < Test::Unit::TestCase
  include OSPFv2

  BASE = ['set routing-options router-id 1.1.1.1',
          'set protocols ospf area 0 interface eth1',
          'set protocols ospf area 0 interface lo passive'].freeze

  def setup
    @dir = Dir.mktmpdir('ospfd-test')
    @path = File.join(@dir, 'ospfd.conf')
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e })
    @hub = Transport::Hub.new
    @system = Daemon::FakeSystem.new
    @system.set('eth1', '10.0.0.1/24')
    @system.set('lo', '1.1.1.1/32')
    @log = []
    @peer = Core::Instance.new(router_id: '2.2.2.2', loop: @loop)
    @peer.add_interface(name: 'e0', address: '10.0.0.2/24', transport: Transport::Loopback.new(@hub, '10.0.0.2'))
    @peer.start
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def daemon(text = nil)
    File.write(@path, text) if text
    @d = Daemon.new(config_path: @path, loop: @loop, system: @system,
                    transport: ->(_name, ip) { Transport::Loopback.new(@hub, ip) },
                    logger: ->(level, msg) { @log << "#{level} #{msg}" })
    @d.start
  end

  def commit!(*lines)
    assert_empty @d.configure(lines)
    r = @d.commit
    assert r[:ok], r[:errors].join("\n")
    r
  end

  def peer_full?
    @peer.neighbors.first&.full?
  end

  def test_starts_from_the_file_and_forms_the_adjacency
    daemon(BASE.join("\n"))
    @loop.run_until(120) { peer_full? }
    assert_equal %w[eth1 lo], @d.instance.interfaces.keys.sort
    assert_equal '1.1.1.1', @d.views.overview[:router_id]
  end

  def test_missing_file_starts_empty_and_a_commit_saves_it
    daemon
    assert_nil @d.instance
    r = commit!(*BASE)
    assert_equal 3, r[:changes].size
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert_equal BASE.map { |l| l.sub('area 0 ', 'area 0.0.0.0 ') }, File.read(@path).lines.drop(1).map(&:chomp)
  end

  def test_broken_file_runs_nothing
    daemon("set routing-options router-id 1.1.1.1\nset protocols bogus\n")
    assert_nil @d.instance
    assert(@log.any? { |l| l.include?('line 2') })
  end

  def test_a_failed_commit_changes_nothing
    daemon(BASE.join("\n"))
    @d.configure(['set protocols ospf area 1 interface eth1'])
    r = @d.commit
    assert !r[:ok]
    assert_match(/eth1 is in area/, r[:errors].join)
    assert_equal '0.0.0.0', @d.instance.interfaces['eth1'].area.id_s
    assert @d.candidate_changed?
  end

  def test_commit_check_applies_nothing
    daemon(BASE.join("\n"))
    @d.configure(['set protocols ospf area 0 interface eth1 metric 50'])
    assert @d.commit(check: true)[:ok]
    assert_equal 10, @d.instance.interfaces['eth1'].cost
  end

  def test_cost_and_authentication_change_without_touching_the_adjacency
    daemon(BASE.join("\n"))
    @loop.run_until(120) { peer_full? }
    @loop.advance(5)
    changes = @peer.neighbors.first.state_changes
    commit!('set protocols ospf area 0 interface eth1 metric 77')
    @loop.advance(20)
    assert_equal 77, @d.instance.interfaces['eth1'].cost
    assert_equal changes, @peer.neighbors.first.state_changes
    link = @peer.area(0).lsdb[[1, Core::Addr.to_i('1.1.1.1'), Core::Addr.to_i('1.1.1.1')]].router_links.find { |l| l.type_name == :transit }
    assert_equal 77, link.metric, 'the peer sees the new cost'

    commit!('set protocols ospf area 0 interface eth1 authentication md5 1 key k')
    assert_equal 'md5 key 1', @d.instance.interfaces['eth1'].summary[:auth]
  end

  def test_other_changes_restart_the_interface
    daemon(BASE.join("\n"))
    @loop.run_until(120) { peer_full? }
    old = @d.instance.interfaces['eth1']
    commit!('set protocols ospf area 0 interface eth1 priority 5')
    assert_not_same old, @d.instance.interfaces['eth1']
    assert_equal 5, @d.instance.interfaces['eth1'].priority
    @loop.run_until(120) { peer_full? }
  end

  def test_interface_removed_from_config
    daemon(BASE.join("\n"))
    @loop.run_until(120) { peer_full? }
    commit!('delete protocols ospf area 0 interface eth1')
    assert_equal ['lo'], @d.instance.interfaces.keys
    @loop.advance(60)
    assert_empty @peer.neighbors, 'the peer lost us'
  end

  def test_interface_waits_for_the_host_then_starts
    @system.remove('eth1')
    daemon(BASE.join("\n"))
    assert_equal({ 'eth1' => 'no such interface on this host' }, @d.pending)
    assert_equal 'pending', @d.views.interfaces.find { |i| i[:name] == 'eth1' }[:state].to_s
    @system.set('eth1', '10.0.0.1/24', up: false)
    @loop.advance(Daemon::RECHECK)
    assert_equal 'interface is down', @d.pending['eth1']
    @system.set('eth1', '10.0.0.1/24')
    @loop.advance(Daemon::RECHECK)
    assert_empty @d.pending
    @loop.run_until(120) { peer_full? }

    # The address goes away: the interface stops, and waits again.
    @system.set('eth1', nil)
    @loop.advance(Daemon::RECHECK)
    assert_equal 'no IPv4 address', @d.pending['eth1']
    assert_nil @d.instance.interfaces['eth1']
  end

  def test_router_id_change_restarts_ospf
    daemon(BASE.join("\n"))
    first = @d.instance
    commit!('set routing-options router-id 9.9.9.9')
    assert_not_same first, @d.instance
    assert !first.running?
    assert_equal '9.9.9.9', @d.instance.router_id_s
    @loop.run_until(120) { peer_full? }
  end

  def test_rollback
    daemon
    commit!(*BASE)
    commit!('set protocols ospf area 0 interface eth1 metric 20')
    commit!('set protocols ospf area 0 interface eth1 metric 30')
    @d.rollback(1)
    assert_equal ['- set protocols ospf area 0.0.0.0 interface eth1 metric 30',
                  '+ set protocols ospf area 0.0.0.0 interface eth1 metric 20'], @d.compare
    @d.rollback(2)
    assert_equal ['- set protocols ospf area 0.0.0.0 interface eth1 metric 30'], @d.compare
    @d.rollback(0)
    assert_empty @d.compare
    assert_raise(Config::Error) { @d.rollback(7) }
    assert_raise(Config::Error) { @d.rollback(10) }
    assert_equal 3, @d.commit_history.size
  end

  def test_load_override
    daemon(BASE.join("\n"))
    @d.load_override("set routing-options router-id 1.1.1.1\nset protocols ospf area 0 interface lo passive\n")
    assert_equal ['- set protocols ospf area 0.0.0.0 interface eth1'], @d.compare
    assert_raise(Config::Error) { @d.load_override('set nonsense') }
    assert_equal ['- set protocols ospf area 0.0.0.0 interface eth1'], @d.compare, 'a bad load keeps the candidate'
  end

  def test_clear_neighbors
    daemon(BASE.join("\n"))
    @loop.run_until(120) { peer_full? }
    assert_equal 1, @d.clear_neighbors
    assert_equal 0, @d.clear_neighbors('7.7.7.7')
    @loop.run_until(120) { peer_full? }
  end

  def test_views
    daemon(BASE.join("\n"))
    @loop.run_until(120) { peer_full? }
    @loop.advance(10)
    v = @d.views
    n = v.neighbors.first
    assert_equal ['2.2.2.2', :full, 'DR', '0.0.0.0'], n.values_at(:router_id, :state, :role, :area)
    eth1 = v.interfaces.find { |i| i[:name] == 'eth1' }
    assert_equal ['2.2.2.2', '1.1.1.1', 'BDR'], eth1.values_at(:dr_id, :bdr_id, :state_name)
    db = v.database(detail: true)
    mine = db.find { |r| r[:type] == 1 && r[:self] }
    assert_equal '0x80000002', mine[:seq].sub(/\d\z/, '2')
    assert_equal %i[transit stub], mine[:detail][:links].map { |l| l[:type] }
    net = db.find { |r| r[:type] == 2 }
    assert_equal %w[1.1.1.1 2.2.2.2], net[:detail][:attached].sort
    assert(v.log.none? { |e| e[:level] == :debug })
    assert_operator v.statistics['eth1'][:rx_hello], :>, 0
  end
end
