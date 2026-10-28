# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'ospfv2/daemon'
require 'ospfv2/command_line/format'
require 'json'

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

  # show timers: every timer with its owner and when it fires, the
  # neighbor's among them; the clock moves, the time left goes down.
  def test_timers
    daemon(BASE.join("\n"))
    @loop.run_until(120) { peer_full? }
    @loop.advance(10) # the last acks and retransmits
    t = @d.views.timers
    by = ->(name) { t[:timers].select { _1[:name] == name } }
    hello = by.('hello').find { _1[:owner][:interface] == 'eth1' }
    assert_equal [{ kind: 'interface', interface: 'eth1' }, true, true, 10], hello.values_at(:owner, :armed, :periodic, :interval)
    assert_operator hello[:due_in], :<=, 10
    inact = by.('inactivity').first
    assert_equal({ kind: 'neighbor', interface: 'eth1', router_id: '2.2.2.2', address: '10.0.0.2' }, inact[:owner])
    assert_operator inact[:due_in], :<=, 40
    assert_equal({ kind: 'router' }, by.('maxage_sweep').first[:owner])
    assert_equal %w[spf spf_holddown spf_learn], t[:timers].select { _1[:owner][:kind] == 'spf' }.map { _1[:name] }.sort
    refresh = by.('ls_refresh').find { _1[:owner][:type] == 1 }
    assert_equal({ kind: 'lsa', area: '0.0.0.0', type: 1, ls_id: '1.1.1.1', advr: '1.1.1.1' }, refresh[:owner])
    assert_operator refresh[:due_in], :>, 1500
    assert_equal({ min_ls_interval: 5, min_ls_arrival: 1, ls_refresh_time: 1800, max_age: 3600 }, t[:constants])
    assert_equal [10, 40], t[:interfaces].find { _1[:name] == 'eth1' }.values_at(:hello_interval, :dead_interval)
    assert_equal [{ interface: 'eth1', router_id: '2.2.2.2', address: '10.0.0.2', state: :full, retransmit: 0, requests: 0 }],
                 t[:neighbors].map { _1.slice(:interface, :router_id, :address, :state, :retransmit, :requests) }
    assert_equal @loop.scheduler.size, t[:timers].count { _1[:armed] }, 'every armed timer is listed, once'
    # The peer shares the loop: its timers are the only ones nobody claims.
    assert_equal @peer.timers.select { _1[2].active? }.map { _1[1].to_s }.sort,
                 t[:timers].select { _1[:owner][:kind] == 'other' }.map { _1[:name] }.sort
    @loop.advance(7)
    later = @d.views.timers
    assert_in_delta refresh[:due_in] - 7, later[:timers].find { _1[:name] == 'ls_refresh' && _1[:owner][:type] == 1 }[:due_in], 0.01
    text = CommandLine::Format.render(:timers, :junos, JSON.parse(JSON.generate(later)))
    assert_match(/^inactivity +neighbor 2.2.2.2 on eth1 +\d+\.\d{3}s +40s/, text)
    assert_match(/^hello +interface eth1 .* every 10s/, text)
  end

  def test_missing_file_starts_empty_and_a_commit_saves_it
    daemon
    assert_nil @d.instance
    r = commit!(*BASE)
    assert_equal 3, r[:changes].size
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert_equal BASE.map { |l| l.sub('area 0 ', 'area 0.0.0.0 ') }, File.read(@path).lines.drop(1).map(&:chomp)
  end

  def test_the_same_statements_give_the_same_file
    daemon
    commit!(*BASE)
    first = File.read(@path)
    @loop.clock.advance(3600)
    commit!('set protocols ospf area 0 interface eth1 metric 5')
    commit!('delete protocols ospf area 0 interface eth1 metric')
    assert_equal first, File.read(@path), 'no date or other noise in the file'
  end

  def test_a_commit_keeps_the_file_mode_without_access_for_others
    { 0o640 => 0o640, 0o664 => 0o660, 0o600 => 0o600, 0o444 => 0o640 }.each do |before, after|
      File.write(@path, BASE.join("\n") + "\n")
      File.chmod(before, @path)
      daemon
      commit!('set protocols ospf area 0 interface eth1 metric 5')
      assert_equal after, File.stat(@path).mode & 0o777, format('%o becomes %o', before, after)
      @d.stop
    end
  end

  def test_a_commit_keeps_the_file_owner
    omit('needs root to give the file away') unless Process.euid.zero?
    File.write(@path, BASE.join("\n") + "\n")
    File.chown(1000, 1000, @path)
    daemon
    commit!('set protocols ospf area 0 interface eth1 metric 5')
    st = File.stat(@path)
    assert_equal [1000, 1000], [st.uid, st.gid]
    assert_match(/metric 5/, File.read(@path))
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

  # ---- review findings ----

  def test_a_broken_file_is_kept_aside_not_lost
    text = "set routing-options router-id 1.1.1.1\n" \
           "set protocols ospf area 0 interface eth1 authentication md5 1 key TOPSECRETTOPSECRETXX\n"
    daemon(text)
    assert_nil @d.instance
    assert_equal "#{@path}.broken", @d.broken_file
    assert_equal text, File.read(@d.broken_file)
    assert_equal 0o600, File.stat(@d.broken_file).mode & 0o777
    assert(@log.none? { |l| l.include?('TOPSECRET') }, 'the secret stays out of the log')
    commit!(*BASE)
    assert_equal text, File.read("#{@path}.broken"), 'a commit does not touch the kept copy'
    assert_nil @d.broken_file
  end

  # A transport factory whose interface +bad+ fails to start until fixed.
  def flaky_transport(bad)
    state = { broken: true }
    factory = lambda do |name, ip|
      t = Transport::Loopback.new(@hub, ip)
      t.define_singleton_method(:start) { |&b| raise PermissionError, 'raw sockets need root' } if name == bad && state[:broken]
      t
    end
    [factory, state]
  end

  def daemon_with(transport, text = nil)
    File.write(@path, text) if text
    @d = Daemon.new(config_path: @path, loop: @loop, system: @system, transport: transport,
                    logger: ->(level, msg) { @log << "#{level} #{msg}" })
    @d.start
  end

  def test_a_transport_that_fails_leaves_no_stuck_interface
    @system.set('eth2', '10.0.2.1/24')
    factory, state = flaky_transport('eth2')
    daemon_with(factory, (BASE + ['set protocols ospf area 0 interface eth2']).join("\n"))
    assert_equal %w[eth1 lo], @d.instance.interfaces.keys.sort, 'startup survives one bad interface'
    assert_equal({ 'eth2' => 'raw sockets need root' }, @d.pending)
    @loop.advance(Daemon::RECHECK * 3)
    assert_equal 1, @log.count { |l| l.include?('eth2: raw sockets need root') }, 'logged once, not on every retry'
    state[:broken] = false
    @loop.advance(Daemon::RECHECK)
    assert @d.instance.interfaces.key?('eth2'), 'retried and started'
    assert_empty @d.pending
  end

  def test_a_failing_interface_can_be_deleted
    @system.set('eth2', '10.0.2.1/24')
    factory, = flaky_transport('eth2')
    daemon_with(factory, (BASE + ['set protocols ospf area 0 interface eth2']).join("\n"))
    commit!('delete protocols ospf area 0 interface eth2')
    assert_empty @d.pending
    assert !@d.instance.interfaces.key?('eth2')
  end

  def test_router_id_change_with_a_failing_interface_keeps_router_and_config_in_step
    @system.set('eth2', '10.0.2.1/24')
    factory, = flaky_transport('eth2')
    daemon_with(factory, BASE.join("\n"))
    r = commit!('set routing-options router-id 9.9.9.9', 'set protocols ospf area 0 interface eth2')
    assert_equal '9.9.9.9', @d.instance.router_id_s
    assert_match(/9\.9\.9\.9/, File.read(@path))
    assert_includes r[:warnings], 'interface eth2: raw sockets need root'
  end

  def test_router_id_change_flushes_the_old_lsas
    daemon(BASE.join("\n"))
    @loop.run_until(120) { peer_full? }
    @loop.advance(10)
    old_key = [1, Core::Addr.to_i('1.1.1.1'), Core::Addr.to_i('1.1.1.1')]
    assert @peer.area(0).lsdb[old_key]
    commit!('set routing-options router-id 9.9.9.9')
    @loop.run_until(30) { (l = @peer.area(0).lsdb[old_key]).nil? || l.max_age? }
  end

  def test_a_save_failure_changes_nothing
    daemon(BASE.join("\n"))
    Dir.mkdir("#{@path}.tmp") # cannot be written as a file
    @d.configure(['set protocols ospf area 0 interface eth1 metric 50'])
    r = @d.commit
    assert !r[:ok]
    assert_match(/cannot save .*nothing changed/, r[:errors].first)
    assert_equal 10, @d.instance.interfaces['eth1'].cost, 'the router did not change'
    assert @d.candidate_changed?
    assert_empty @d.commit_history
  end

  def test_history_lists_saved_commits_so_numbers_match_rollbacks
    daemon(BASE.join("\n")) # the startup commit is not saved
    commit!('set protocols ospf area 0 interface eth1 metric 20')
    commit!('set protocols ospf area 0 interface eth1 metric 30')
    assert_equal 2, @d.commit_history.size
    @d.rollback(1)
    assert_equal ['- set protocols ospf area 0.0.0.0 interface eth1 metric 30',
                  '+ set protocols ospf area 0.0.0.0 interface eth1 metric 20'], @d.compare
  end

  def test_comments_are_cleaned
    daemon
    @d.configure(BASE)
    @d.commit(comment: "first\n2026-10-27T00:00:00Z error FORGED#{'x' * 300}")
    c = @d.commit_history.first[:comment]
    assert_no_match(/\n/, c)
    assert_operator c.size, :<=, 200
  end

  def test_an_area_left_empty_goes_away
    daemon((BASE + ['set protocols ospf area 1 interface eth2']).join("\n"))
    @system.set('eth2', '10.0.2.1/24')
    @loop.advance(Daemon::RECHECK)
    assert_equal %w[0.0.0.0 0.0.0.1], @d.instance.areas.values.map(&:id_s).sort
    commit!('delete protocols ospf area 1')
    @loop.advance(5)
    assert_equal %w[0.0.0.0], @d.instance.areas.values.map(&:id_s)
  end

  def test_a_loopback_only_address_runs_passive_only
    @system.set('lo', '127.0.0.1/8')
    daemon((BASE.take(2) + ['set protocols ospf area 0 interface lo']).join("\n"))
    assert_equal 'only a 127/8 address', @d.pending['lo']
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
