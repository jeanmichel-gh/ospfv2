# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'json'
require 'ospfv2/daemon'
require 'ospfv2/daemon/api'
require 'support/fake_bfd_client'

# ospfd and BFD: bfd-liveness-detection in the configuration, the link to
# bfdd4r (Daemon::BfdLink), and what the API shows. A fake client on a fake
# clock, and a core peer on an in-memory segment, as daemon_test.rb has it.
class TestDaemonBfd < Test::Unit::TestCase
  include OSPFv2

  BASE = ['set routing-options router-id 1.1.1.1',
          'set protocols ospf area 0 interface eth1'].freeze
  BFD_LINE = 'set protocols ospf area 0 interface eth1 bfd-liveness-detection minimum-interval 100'

  def setup
    @dir = Dir.mktmpdir('ospfd-bfd')
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e })
    @hub = Transport::Hub.new
    @system = Daemon::FakeSystem.new
    @system.set('eth1', '10.0.0.1/24')
    @peer = Core::Instance.new(router_id: '2.2.2.2', loop: @loop)
    @peer.add_interface(name: 'e0', address: '10.0.0.2/24', transport: Transport::Loopback.new(@hub, '10.0.0.2'))
    @peer.start
    @client = FakeBfdClient.new
    @names = []
    @log = []
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def daemon(*lines, bfd: true)
    factory = bfd ? ->(name) { @names << name; @client } : nil
    @d = Daemon.new(config_path: File.join(@dir, 'ospfd.conf'), loop: @loop, system: @system, bfd: factory,
                    transport: ->(_n, ip) { Transport::Loopback.new(@hub, ip) },
                    logger: ->(level, msg) { @log << "#{level} #{msg}" })
    @d.start
    commit!(*lines)
    @loop.run_until(120) { full? }
  end

  def commit!(*lines)
    assert_empty @d.configure(lines)
    r = @d.commit
    assert r[:ok], r[:errors].join("\n")
    r
  end

  def full? = @peer.neighbors.first&.full? && nbr&.full?
  def nbr = @d.instance.neighbors.first

  def test_configured_interface_wants_a_session
    daemon(*BASE, BFD_LINE)
    assert_equal ['ospfd'], @names, 'the client name'
    assert_equal({ interface: 'eth1', peer: '10.0.0.2', local: '10.0.0.1',
                   desired_min_tx: 100_000, required_min_rx: 100_000 }, @client.wanted[%w[eth1 10.0.0.2]])
  end

  # The link's poll hands the client's events to the loop with post; the
  # router acts on them there.
  def test_bfd_down_through_the_link
    daemon(*BASE, BFD_LINE)
    @client.up('eth1', '10.0.0.2')
    @d.bfd_link.poll
    @loop.drain
    assert_equal 'up', @d.views.neighbors.first[:bfd]
    @client.failure('eth1', '10.0.0.2')
    @d.bfd_link.poll
    assert nbr&.full?, 'nothing happens before the loop runs it'
    @loop.drain
    assert_nil nbr
    down = @d.instance.events.find { |e| e.kind == :neighbor && e.data[:to] == 'down' }
    assert_equal 'BFD down', down.data[:event]
    assert_equal [@loop.clock.now, @loop.clock.now], @client.polls, 'poll is given the loop clock'
  end

  # The loop's queue full, as under a packet flood: a BFD event still
  # gets in. offer would drop it; the link posts.
  def test_bfd_down_is_never_dropped
    daemon(*BASE, BFD_LINE)
    @client.up('eth1', '10.0.0.2')
    @client.failure('eth1', '10.0.0.2')
    EventLoop::MAX_QUEUE.times { @loop.post {} }
    @d.bfd_link.poll
    @loop.drain
    assert_nil nbr
    assert_equal 0, @loop.dropped
  end

  def test_no_thread_on_a_fake_clock
    daemon(*BASE, BFD_LINE)
    refute @d.bfd_link.running?
  end

  # A field routescope reads: show.neighbors bfd, absent without BFD.
  def test_show_neighbors_bfd_field
    daemon(*BASE, BFD_LINE)
    api = Daemon::Api.new(@d, path: File.join(@dir, 's', 'ospfd.sock'))
    row = -> { JSON.parse(JSON.generate(api.handle('id' => 1, 'method' => 'show.neighbors', 'params' => {})[:result])).first }
    assert_equal 'down', row.call['bfd']
    @client.up('eth1', '10.0.0.2')
    @d.bfd_link.poll
    @loop.drain
    assert_equal 'up', row.call['bfd']
    commit!('delete protocols ospf area 0 interface eth1 bfd-liveness-detection')
    refute row.call.key?('bfd')
    assert_include api.handle('id' => 2, 'method' => 'api.info', 'params' => {})[:result][:event_kinds], 'bfd'
  end

  # Adding or removing it on a running interface keeps the adjacency.
  def test_commit_turns_it_on_and_off_live
    daemon(*BASE)
    assert_empty @names, 'no client until an interface asks for BFD'
    changes = nbr.state_changes
    commit!(BFD_LINE)
    assert @client.wanted?(interface: 'eth1', peer: '10.0.0.2')
    commit!('delete protocols ospf area 0 interface eth1 bfd-liveness-detection')
    assert_empty @client.wanted
    assert_equal changes, nbr.state_changes
    assert nbr.full?
  end

  def test_without_a_client_it_says_so
    daemon(*BASE, BFD_LINE, bfd: false)
    assert nbr.full?
    assert_nil @d.bfd_link
    refute nbr.summary.key?(:bfd)
    assert_equal 1, @log.count { _1.include?('bfd-liveness-detection on eth1: this ospfd runs without a BFD client') }
  end

  # bin/ospfd on a host without bfd4r: it runs, and says why there is
  # no BFD.
  def test_without_bfd4r_installed
    @d = Daemon.new(config_path: File.join(@dir, 'ospfd.conf'), loop: @loop, system: @system,
                    bfd: ->(_) { raise LoadError, 'cannot load such file -- bfd/client' },
                    transport: ->(_n, ip) { Transport::Loopback.new(@hub, ip) },
                    logger: ->(level, msg) { @log << "#{level} #{msg}" })
    @d.start
    commit!(*BASE, BFD_LINE)
    @loop.run_until(120) { full? }
    assert_include @log, 'error bfd-liveness-detection on eth1: cannot load bfd4r ' \
                         '(cannot load such file -- bfd/client); running without BFD'
    refute nbr.summary.key?(:bfd)
  end

  def test_stop_lets_the_sessions_go
    daemon(*BASE, BFD_LINE)
    @d.stop
    assert_empty @client.wanted
    assert @client.closed?, 'the connections to bfdd4r closed'
  end

  # bin/ospfd's client is bfd4r's, named ospfd. Making one connects to
  # nothing: poll does.
  def test_the_real_client
    c = Daemon::BFD_CLIENT.call('ospfd')
    assert_instance_of BFD::Client, c
    assert_equal 'ospfd', c.name
    refute c.connected?
    %i[interface peer local].each { |k| assert_include BFD::Client.instance_method(:want).parameters, [:keyreq, k] }
    assert_equal [%i[keyreq interface], %i[keyreq peer]], BFD::Client.instance_method(:drop).parameters
  end
end

# The link's thread, on a real loop: it polls without being asked and
# posts what it gets.
class TestDaemonBfdLink < Test::Unit::TestCase
  include OSPFv2

  def test_thread_polls_and_posts
    loop = EventLoop.new.start
    client = FakeBfdClient.new
    got = Queue.new
    link = Daemon::BfdLink.new(client, loop: loop) do |events|
      loop.post { got << [events.map(&:state), loop.on_loop_thread?] }
    end
    refute link.running?, 'no thread before a session is wanted'
    client.up('eth1', '10.0.0.2')
    link.want(interface: 'eth1', peer: '10.0.0.2', local: '10.0.0.1')
    assert link.running?
    assert_equal [[:up], true], got.pop(timeout: 5)
  ensure
    link&.stop
    loop&.stop
  end
end
