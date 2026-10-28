# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'ospfv2/daemon'

# The event bus on its own.
class TestDaemonEvents < Test::Unit::TestCase
  include OSPFv2

  def setup
    @bus = Daemon::Events.new
    @t = Time.utc(2026, 10, 28, 3, 18, 31)
  end

  def pub(kind = :log, msg = 'x', **data)
    @bus.publish(time: @t, level: :info, kind: kind, message: msg, data: data)
  end

  def test_events_are_numbered_and_shaped_for_json
    ev = pub(:neighbor, 'n', router_id: '2.2.2.2')
    assert_equal 1, ev[:seq]
    assert_equal '2026-10-28T03:18:31.000Z', ev[:time]
    assert_equal %w[info neighbor], [ev[:level], ev[:kind]]
    assert_equal({ router_id: '2.2.2.2' }, ev[:data])
    assert_equal 2, pub[:seq]
    assert_equal 2, @bus.seq
  end

  def test_a_subscriber_gets_what_follows_filtered_by_kind
    sub, replayed = @bus.subscribe(kinds: %w[spf])
    assert_equal 0, replayed
    pub(:neighbor)
    pub(:spf, 'run')
    assert_equal 'run', sub.pop(timeout: 0)[:message]
    assert_nil sub.pop(timeout: 0)
  end

  def test_replay_from_a_sequence_number
    5.times { |i| pub(:log, "e#{i}") }
    sub, replayed = @bus.subscribe(since: 3)
    assert_equal 2, replayed
    assert_equal %w[e3 e4], [sub.pop(timeout: 0), sub.pop(timeout: 0)].map { |e| e[:message] }
  end

  def test_replay_counts_only_the_kinds_asked_for
    pub(:neighbor)
    pub(:spf, 'run')
    pub(:neighbor)
    sub, replayed = @bus.subscribe(kinds: %w[spf], since: 0)
    assert_equal 1, replayed
    assert_equal 'run', sub.pop(timeout: 0)[:message]
    assert_nil sub.pop(timeout: 0)
  end

  def test_backlog_is_bounded
    (Daemon::Events::BACKLOG + 10).times { pub }
    _, replayed = @bus.subscribe(since: 0)
    assert_equal Daemon::Events::BACKLOG, replayed
  end

  def test_unknown_kinds_are_refused
    e = assert_raise(ArgumentError) { @bus.subscribe(kinds: %w[neighbor bogus]) }
    assert_match(/unknown event kind bogus/, e.message)
  end

  def test_a_slow_subscriber_loses_the_oldest_and_is_told
    sub, = @bus.subscribe
    (Daemon::Events::MAX_QUEUE + 3).times { |i| pub(:log, "e#{i}") }
    over = sub.pop(timeout: 0)
    assert_equal 'overflow', over[:kind]
    assert_equal 3, over[:data][:dropped]
    assert_equal 'e3', sub.pop(timeout: 0)[:message], 'the oldest went first'
  end

  def test_pop_waits_for_an_event
    sub, = @bus.subscribe
    Thread.new { sleep 0.05; pub(:log, 'later') }
    assert_equal 'later', sub.pop(timeout: 2)[:message]
  end

  def test_close_unsubscribes
    sub, = @bus.subscribe
    assert_equal 1, @bus.subscribers
    sub.close
    assert_equal 0, @bus.subscribers
    pub
    assert_nil sub.pop(timeout: 0)
  end
end

# Events from a running daemon: the core's, with kind and data, and the
# daemon's own.
class TestDaemonEventStream < Test::Unit::TestCase
  include OSPFv2

  def setup
    @dir = Dir.mktmpdir('ospfd-events')
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e })
    @hub = Transport::Hub.new
    system = Daemon::FakeSystem.new
    system.set('eth1', '10.0.0.1/24')
    @d = Daemon.new(config_path: File.join(@dir, 'ospfd.conf'), loop: @loop, system: system,
                    transport: ->(_name, ip) { Transport::Loopback.new(@hub, ip) })
    @peer = Core::Instance.new(router_id: '2.2.2.2', loop: @loop)
    @peer.add_interface(name: 'e0', address: '10.0.0.2/24', transport: Transport::Loopback.new(@hub, '10.0.0.2'))
    @peer.start
    @d.start
    @sub, = @d.events.subscribe
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def drain
    out = []
    while (e = @sub.pop(timeout: 0))
      out << e
    end
    out
  end

  def commit!(*lines)
    assert_empty @d.configure(lines)
    assert @d.commit(comment: 'test')[:ok]
  end

  def test_commit_and_adjacency_events
    commit!('set routing-options router-id 1.1.1.1', 'set protocols ospf area 0 interface eth1')
    @loop.run_until(120) { @peer.neighbors.first&.full? }
    evs = drain
    kinds = evs.map { |e| e[:kind] }

    commit = evs.find { |e| e[:kind] == 'commit' }
    assert_equal 'test', commit[:data][:comment]
    assert_equal 2, commit[:data][:changes]
    assert_include commit[:data][:statements], '+ set protocols ospf area 0.0.0.0 interface eth1'
    assert_equal true, commit[:data][:saved]

    assert_include kinds, 'router'
    assert_include kinds, 'interface'
    full = evs.find { |e| e[:kind] == 'neighbor' && e[:data][:to] == 'full' }
    assert full, "no neighbor full event in #{kinds.uniq}"
    assert_equal 'eth1', full[:interface]
    assert_equal '2.2.2.2', full[:data][:router_id]
    assert_equal '10.0.0.2', full[:data][:address]
    assert_equal 'new', evs.find { |e| e[:kind] == 'neighbor' }[:data][:to], 'first, the new neighbor'

    seqs = evs.map { |e| e[:seq] }
    assert_equal seqs.sort, seqs, 'in order'
    assert_equal seqs.uniq, seqs
  end

  def test_every_spf_run_is_an_event_but_not_in_the_event_list
    commit!('set routing-options router-id 1.1.1.1', 'set protocols ospf area 0 interface eth1')
    @loop.run_until(120) { @peer.neighbors.first&.full? }
    @loop.advance(30)
    spf = drain.select { |e| e[:kind] == 'spf' }
    refute_empty spf
    run = spf.last
    assert_kind_of Float, run[:data][:duration_ms]
    assert_kind_of Integer, run[:data][:routes]
    refute_empty run[:data][:reasons]
    assert(run[:data][:reasons].all? { |r| r.key?(:kind) && r.key?(:detail) })
    assert_equal @d.instance.spf_log.size, spf.size
    refute(@d.instance.events.any? { |e| e.kind == :spf }, 'show ospf events stays as it was')
  end

  def test_events_before_there_is_a_router
    assert_nil @d.instance
    @d.log(:info, 'hello', kind: :log)
    assert_equal 'hello', drain.last[:message]
  end

  def test_lsa_events_carry_the_instance_key
    commit!('set routing-options router-id 1.1.1.1', 'set protocols ospf area 0 interface eth1')
    @loop.run_until(120) { @peer.neighbors.first&.full? }
    drain
    commit!('set routing-options router-id 1.1.1.9') # restart: our old LSAs are flushed
    @loop.advance(5)
    flush = drain.find { |e| e[:kind] == 'lsa' && e[:data][:change] == 'flush' }
    assert flush
    assert_equal %i[lsa_type ls_id advr seq change].sort, flush[:data].keys.sort
    assert_match(/\A0x[0-9a-f]{8}\z/, flush[:data][:seq])
    assert_equal '1.1.1.1', flush[:data][:advr]
  end
end
