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
    @d = Daemon.new(config_path: File.join(@dir, 'ospfd.conf'), loop: @loop, system: system, fib: factory,
                    transport: ->(_n, ip) { Transport::Loopback.new(hub, ip) },
                    logger: ->(l, m) { @log << "#{l} #{m}" })
    @d.start
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
    commit!('set routing-options kernel table 100', 'set routing-options kernel protocol 99')
    assert_empty kernel
    assert_equal [ROUTE], kernel(99, 100)
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
end
