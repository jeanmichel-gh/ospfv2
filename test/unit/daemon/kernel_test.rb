# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'ospfv2/daemon'

# routing-options kernel: the daemon installing routes, over in-memory
# kernel tables it opens through the fib factory.
class TestDaemonKernel < Test::Unit::TestCase
  include OSPFv2

  BASE = ['set routing-options router-id 1.1.1.1',
          'set protocols ospf area 0 interface eth1',
          'set protocols ospf area 0 interface lo passive'].freeze

  def setup
    @dir = Dir.mktmpdir('ospfd-kernel')
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e })
    hub = Transport::Hub.new
    system = Daemon::FakeSystem.new
    system.set('eth1', '10.0.0.1/24')
    system.set('lo', '1.1.1.1/32')
    @peer = Core::Instance.new(router_id: '2.2.2.2', loop: @loop)
    @peer.add_interface(name: 'e0', address: '10.0.0.2/24', transport: Transport::Loopback.new(hub, '10.0.0.2'))
    @peer.add_interface(name: 'lo', address: '2.2.2.2/32', passive: true)
    @peer.start
    @tables = {}   # [protocol, table] => Fib::Memory, as the daemon opened them
    @refuse = nil
    factory = lambda do |protocol:, table:|
      raise Errno::EPERM, 'netlink' if @refuse
      @tables[[protocol, table]] ||= Fib::Memory.new
    end
    @log = []
    @system = system
    @hub = hub
    @factory = factory
    @d = new_daemon
    @d.start
  end

  def new_daemon
    Daemon.new(config_path: File.join(@dir, 'ospfd.conf'), loop: @loop, system: @system, fib: @factory,
               transport: ->(_n, ip) { Transport::Loopback.new(@hub, ip) },
               logger: ->(l, m) { @log << "#{l} #{m}" })
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def commit!(*lines)
    assert_empty @d.configure(lines)
    r = @d.commit
    assert r[:ok], r[:errors].join("\n")
    r
  end

  def kernel(protocol = 89, table = 254) = (@tables[[protocol, table]]&.dump || []).map(&:to_s).sort

  ROUTE = '2.2.2.2/32 via 10.0.0.2 eth1 metric 20'

  def converge
    commit!(*BASE)
    assert @loop.run_until(120) { kernel.include?(ROUTE) }
  end

  # SR (docs/design/sr-ospf.md, step 4, PR 6): the host is asked to take
  # label routes on ospfd's interfaces, up to the top of its blocks; label
  # routes and pushes go in, and show.fib lists them.
  def sr_peer
    @peer.opaque = true
    @peer.segment_routing = { srgb: [17_000, 8_000], srlb: [15_000, 1_000], index: 2 }
  end

  SR = 'set protocols ospf source-packet-routing node-segment ipv4-index 1'

  def labels = (@tables[[89, 254]]&.dump_labels || []).map(&:to_s).sort

  def test_label_routes_go_in
    sr_peer
    commit!(*BASE, SR)
    assert @loop.run_until(120) { labels.include?('label 16002 pop via 10.0.0.2 dev eth1') }
    assert_equal [[['eth1'], 23_999]], @system.mpls_calls.uniq, 'non-passive interfaces, the SRGB\'s top'
    v = @d.views.fib
    assert_equal true, v[:labels_on]
    row = v[:labels].find { _1[:label] == 16_002 }
    assert_equal [:installed, [{ interface: 'eth1', gateway: '10.0.0.2', out_label: nil }]], row.values_at(:state, :want)
  end

  def test_a_host_without_mpls_gets_ip_routes_only
    sr_peer
    @system.mpls_answer = '/proc/sys/net/mpls/platform_labels is missing: is the mpls_router module loaded?'
    commit!(*BASE, SR)
    assert @loop.run_until(120) { kernel.include?(ROUTE) }
    assert_empty labels
    assert_equal false, @d.views.fib[:labels_on]
    assert_equal 1, @log.count { _1.include?('SR: label routes not installed: /proc/sys/net/mpls/platform_labels is missing') }
  end

  def test_routes_go_in_with_the_defaults
    converge
    assert_equal [ROUTE], kernel
    v = @d.views.fib
    assert_equal [89, 254, 20], v.values_at(:protocol, :table, :metric)
    assert_equal [[:installed, '2.2.2.2/32']], v[:routes].map { |r| [r[:state], r[:prefix]] }
    assert_equal({ install: true, installed: 1, failed: 0, held: 0, protocol: 89, table: 254 }, @d.views.overview[:fib])
  end

  def test_a_new_metric_applies_in_place
    converge
    commit!('set routing-options kernel metric 200')
    assert_equal [ROUTE.sub('metric 20', 'metric 200')], kernel
    assert_equal 1, @tables.size, 'same table, same backend'
  end

  def test_a_new_table_or_protocol_moves_the_routes
    converge
    commit!('set routing-options kernel table 100', 'set routing-options kernel protocol 77')
    assert_empty kernel
    assert_equal [ROUTE], kernel(77, 100)
  end

  def test_no_install_withdraws_and_install_again_restores
    converge
    commit!('set routing-options kernel no-install')
    assert_empty kernel
    assert_equal false, @d.views.fib[:install]
    assert_nil @d.fib
    commit!('delete routing-options kernel no-install')
    assert_equal [ROUTE], kernel
  end

  def test_a_kernel_we_cannot_open_is_reported_and_retried_on_commit
    @refuse = true
    commit!(*BASE)
    assert_match(/cannot open the kernel routing table/, @d.views.fib[:error])
    assert(@log.any? { |l| l.include?('routes are computed, not installed') })
    @refuse = false
    commit!('set protocols ospf area 0 interface eth1 metric 10')
    assert @loop.run_until(60) { kernel.include?(ROUTE) }
    assert_nil @d.views.fib[:error]
  end

  def test_the_kernel_tables_reserved_for_the_system_are_refused
    assert_empty @d.configure(BASE + ['set routing-options kernel table 255'])
    r = @d.commit
    refute r[:ok]
    assert_match(/table 255 is the kernel's local table/, r[:errors].join)
  end

  def test_a_new_router_id_and_a_stop_withdraw
    converge
    commit!('set routing-options router-id 1.1.1.9')
    assert @loop.run_until(120) { kernel.include?(ROUTE) }, 'the new router installs again'
    @d.stop
    assert_empty kernel
  end

  # ---- review fixes ----

  def old_route(protocol, table)
    r = Fib::Route.new(Core::Addr.to_i('8.8.8.0'), 24, [['eth1', Core::Addr.to_i('10.0.0.2')]], 20)
    (@tables[[protocol, table]] ||= Fib::Memory.new).table[r.kernel_key] = r
  end

  def test_routes_left_under_old_settings_are_swept
    converge
    commit!('set routing-options kernel protocol 77')
    assert_equal "77 254\n", File.read(File.join(@dir, 'ospfd.conf.kernel'))
    old_route(77, 254)            # a crash left this behind
    @d.stop
    old_route(77, 254)
    File.write(File.join(@dir, 'ospfd.conf'), BASE.join("\n"))   # restart with the default id
    @d = new_daemon
    @d.start
    assert_empty kernel(77, 254), 'swept'
    assert(@log.any? { |l| l.include?('removed 1 routes left under protocol 77 table 254') })
    assert_equal "89 254\n", File.read(File.join(@dir, 'ospfd.conf.kernel'))
  end

  def test_no_install_sweeps_what_a_crash_left
    converge
    old_route(89, 254)
    commit!('set routing-options kernel no-install')
    assert_empty kernel
    refute File.exist?(File.join(@dir, 'ospfd.conf.kernel'))
  end

  def test_ids_and_metrics_others_use_are_refused
    { 'protocol 16' => /protocol 16 is dhcp's/, 'protocol 196' => /static \(FRR\)/, 'metric 0' => /not within range/ }.each do |stmt, why|
      errs = @d.configure(["set routing-options kernel #{stmt}"])
      if errs.empty?
        r = @d.commit
        refute r[:ok], stmt
        assert_match(why, r[:errors].join, stmt)
      else
        assert_match(why, errs.join, stmt)
      end
      @d.discard
    end
  end

  def test_debug_lines_stay_out_of_the_event_list
    converge
    assert(@d.instance.events.none? { |e| e.level == :debug })
  end
end
