# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'ospfv2/fib'
require 'support/core_lab'

# The FIB manager on a fake clock, over the in-memory kernel table.
#
#  R1 eth0 --- 10.0.12.0/24 --- R2 eth0 ; R2 eth1 --- 10.0.23.0/30 (p2p) --- R3
#  each with a passive loopback. The manager installs R1's routes.
class TestFibManager < Test::Unit::TestCase
  include OSPFv2

  A = ->(s) { Core::Addr.to_i(s) }

  def setup
    @lab = CoreLab.new
    a = @lab.segment
    b = @lab.segment
    @r1 = @lab.router('1.1.1.1', [a, '10.0.12.1/24'], [:passive, '1.1.1.1/32'])
    @r2 = @lab.router('2.2.2.2', [a, '10.0.12.2/24'], [b, '10.0.23.1/30', { type: :p2p }], [:passive, '2.2.2.2/32'])
    @r3 = @lab.router('3.3.3.3', [b, '10.0.23.2/30', { type: :p2p }], [:passive, '3.3.3.3/32'])
    @kernel = Fib::Memory.new
    @log = []
    @fib = Fib::Manager.new(loop: @lab.loop, backend: @kernel, logger: ->(l, m) { @log << [l, m] })
  end

  def kroute(prefix, hops, metric = 20)
    p, len = prefix.split('/')
    Fib::Route.new(A[p], len.to_i, hops.map { |i, g| [i, g && A[g]] }, metric)
  end

  def kernel_s = @kernel.dump.map(&:to_s).sort

  def converge
    @lab.start
    assert @lab.run_until(120) { @r1.routes.key?([A['3.3.3.3'], 32]) && !@r1.spf.pending? }
  end

  WANT = ['10.0.23.0/30 via 10.0.12.2 eth0 metric 20', '2.2.2.2/32 via 10.0.12.2 eth0 metric 20',
          '3.3.3.3/32 via 10.0.12.2 eth0 metric 20'].freeze

  def test_installs_routes_through_a_gateway_only
    @fib.attach(@r1)
    converge
    assert_equal WANT, kernel_s
    assert @r1.routes.key?([A['10.0.12.0'], 24]), 'the LAN is a route, but the kernel has it as connected'
    assert @fib.status.all? { |e| e.state == :installed }
  end

  def test_withdrawn_routes_are_deleted_after_the_changes
    @fib.attach(@r1)
    converge
    @kernel.calls.clear
    @r2.remove_interface('eth1')
    assert @lab.run_until(60) { !@r1.routes.key?([A['3.3.3.3'], 32]) }
    assert_equal ['2.2.2.2/32 via 10.0.12.2 eth0 metric 20'], kernel_s
    assert_equal %i[delete delete], @kernel.calls.map(&:first)
  end

  # Just enough of a router for the manager: routes and a change hook.
  FakeRouter = Struct.new(:routes, :neighbors, :spf, :hooks) do
    def on_route_change(&block) = hooks << block
  end

  def test_ecmp_is_one_route_with_several_next_hops
    hop = ->(gw) { Core::Spf::NextHop.new('eth0', A[gw]) }
    r = Core::Spf::Route.new(prefix: A['9.0.0.0'], prefix_len: 8, path_type: :intra, cost: 5,
                             next_hops: [hop['10.0.12.3'], hop['10.0.12.2']])
    mixed = Core::Spf::Route.new(prefix: A['10.0.0.0'], prefix_len: 24, path_type: :intra, cost: 5,
                                 next_hops: [hop['10.0.12.3'], Core::Spf::NextHop.new('eth1', nil)])
    @fib.attach(FakeRouter.new({ r.dest_s => r, mixed.dest_s => mixed }, [], nil, []))
    assert_equal ['9.0.0.0/8 via 10.0.12.2 eth0, via 10.0.12.3 eth0 metric 20'], kernel_s,
                 'a network also reached directly is connected: left out'
  end

  def test_a_refused_route_is_retried
    @kernel.fail[[A['3.3.3.3'], 32]] = 'Network is unreachable'
    @fib.attach(@r1)
    converge
    assert_equal WANT - [WANT[2]], kernel_s
    e = @fib.status.find { |x| x.key[0] == A['3.3.3.3'] }
    assert_equal [:failed, 'Network is unreachable'], [e.state, e.error]
    assert_equal 1, @log.count { |_, m| m.include?('could not install 3.3.3.3/32') }
    @lab.advance(12)
    assert_equal 1, @log.count { |_, m| m.include?('could not install 3.3.3.3/32') }, 'said once, retried quietly'
    @kernel.fail.clear
    @lab.advance(6)
    assert_equal WANT, kernel_s
    assert_empty @fib.failed
    assert(@log.any? { |l, m| l == :info && m.start_with?('FIB installed 3.3.3.3/32') })
  end

  def test_routes_from_before_a_restart_are_held_until_converged
    @kernel.replace(kroute('3.3.3.3/32', [['eth0', '10.0.12.9']]))  # changes once OSPF knows better
    @kernel.replace(kroute('8.8.8.0/24', [['eth0', '10.0.12.2']]))  # OSPF will not have it
    @fib.attach(@r1)
    assert @fib.holding?
    assert_equal 2, @kernel.dump.size, 'nothing removed while OSPF has learned nothing'
    @lab.start
    assert @lab.run_until(120) { @r1.neighbors.any?(&:full?) }
    assert(kernel_s.any? { |r| r.start_with?('8.8.8.0/24') }, 'kept while the database settles')
    assert @lab.run_until(120) { !@fib.holding? }
    assert_equal WANT, kernel_s
    assert(@log.any? { |_, m| m.include?('converged, removing 1 routes') })
  end

  def test_the_hold_ends_after_a_minute_without_neighbors
    @kernel.replace(kroute('8.8.8.0/24', [['eth0', '10.0.12.2']]))
    @r1.start
    @fib.attach(@r1)
    @lab.advance(59)
    assert_equal 1, @kernel.dump.size
    assert_equal :held, @fib.status.first.state
    @lab.advance(1.5)
    assert_empty @kernel.dump
    assert(@log.any? { |_, m| m.include?('hold time is up') })
  end

  def test_reconcile_repairs_drift
    @fib.attach(@r1)
    converge
    @kernel.table.delete(@kernel.table.keys.first)
    @kernel.table[[A['7.0.0.0'], 8, 20]] = kroute('7.0.0.0/8', [['eth0', '10.0.12.7']])
    @lab.advance(61)
    assert_equal WANT, kernel_s
    assert_equal 2, @fib.repairs
    assert_equal 2, @log.count { |_, m| m.start_with?('FIB repair') }
    refute_nil @fib.last_reconcile
  end

  def test_a_new_metric_replaces_then_deletes
    @fib.attach(@r1)
    converge
    @kernel.calls.clear
    @fib.metric = 100
    assert_equal WANT.map { |w| w.sub('metric 20', 'metric 100') }, kernel_s
    assert_equal [:add] * 3 + [:delete] * 3, @kernel.calls.map(&:first)
  end

  def test_detach_withdraws_everything
    @fib.attach(@r1)
    converge
    @fib.detach
    assert_empty @kernel.dump
    @r1.interfaces['eth0'].cost = 50
    @lab.advance(30)
    assert_empty @kernel.dump, 'no longer following the router'
  end

  def test_stopping_the_router_withdraws_its_routes
    @fib.attach(@r1)
    converge
    @r1.stop
    assert_empty @kernel.dump
  end

  # ---- review fixes ----

  def test_another_protocols_route_is_never_overwritten
    @kernel.foreign << [A['3.3.3.3'], 32, 20]  # a static route, same prefix, same metric
    @fib.attach(@r1)
    converge
    e = @fib.status.find { |x| x.key[0] == A['3.3.3.3'] }
    assert_equal :failed, e.state
    assert_match(/another route to 3\.3\.3\.3\/32 with metric 20 is in the kernel/, e.error)
    assert_equal WANT - [WANT[2]], kernel_s
    assert_equal [:add], @kernel.calls.select { |_, r| r.start_with?('3.3.3.3') }.map(&:first).uniq,
                 'added, never replaced'
  end

  def test_a_route_already_ours_is_replaced
    @fib.attach(@r1)
    converge
    @kernel.calls.clear
    @r2.interfaces['eth1'].cost = 50
    assert @lab.run_until(30) { @r1.routes[[A['3.3.3.3'], 32]].cost == 70 }
    assert_equal [], @kernel.calls, 'same next hop: nothing to change in the kernel'
  end

  def test_detach_does_not_leave_a_retry_behind
    @fib.attach(@r1)
    converge
    @kernel.fail[[A['2.2.2.2'], 32]] = 'Operation not permitted'
    @fib.detach
    @kernel.calls.clear
    @lab.advance(30)
    assert_empty @kernel.calls, 'no retry once detached'
    assert(@log.any? { |_, m| m.include?('1 routes could not be withdrawn') })
    assert_equal ['2.2.2.2/32 via 10.0.12.2 eth0 metric 20'], kernel_s
  end

  # R1 restarts with a held route through a LAN whose DR election takes
  # the 40 s wait, and a point-to-point neighbor that is Full in seconds.
  # The hold must outlast the LAN.
  def test_the_hold_waits_for_every_adjacency
    lab = CoreLab.new(seed: 3)
    lan = lab.segment
    p2p = lab.segment
    r1 = lab.router('1.1.1.1', [lan, '10.0.12.1/24'], [p2p, '10.0.13.1/30', { type: :p2p }])
    lab.router('2.2.2.2', [lan, '10.0.12.2/24', { priority: 0 }], [:passive, '2.2.2.2/32'])
    lab.router('3.3.3.3', [p2p, '10.0.13.2/30', { type: :p2p }], [:passive, '3.3.3.3/32'])
    kernel = Fib::Memory.new
    held = kroute('2.2.2.2/32', [['eth0', '10.0.12.2']])
    kernel.replace(held)
    fib = Fib::Manager.new(loop: lab.loop, backend: kernel)
    fib.attach(r1)
    lab.start
    assert lab.run_until(30) { r1.routes.key?([A['3.3.3.3'], 32]) && r1.spf.state == :quiet }
    assert_equal :waiting, r1.interfaces['eth0'].state, 'the LAN is still electing'
    assert fib.holding?
    assert lab.run_until(120) { !fib.holding? }
    assert_include kernel.dump.map(&:to_s), held.to_s
    assert(kernel.calls.none? { |op, r| op == :delete && r == held.to_s }, 'the LAN route never left the kernel')
  end

  def test_the_hold_waits_for_the_host_to_be_ready
    ready = false
    fib = Fib::Manager.new(loop: @lab.loop, backend: @kernel, settled: -> { ready }, hold: 300)
    @kernel.replace(kroute('8.8.8.0/24', [['eth0', '10.0.12.2']]))
    fib.attach(@r1)
    @lab.start
    assert @lab.run_until(120) { @lab.full?(@r1, @r2) && @r1.spf.state == :quiet }
    @lab.advance(5)
    assert fib.holding?, 'an interface still pending on the host'
    ready = true
    @lab.advance(2)
    refute fib.holding?
  end
end
