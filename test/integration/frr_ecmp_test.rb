# frozen_string_literal: true

require 'test/unit'
require 'support/frr_topology'

# Equal-cost failover in the kernel. Opt in with OSPFV2_FRR=1 as root with
# FRR installed:
#
#   sudo OSPFV2_FRR=1 ruby -Ilib -Itest test/integration/frr_ecmp_test.rb
#
#   r1 (core) ==two p2p links== r2 (FRR, loopback 2.2.2.2)
#
# The route to 2.2.2.2 goes in as one multipath route over both links.
# When one link fails it drops to the other within the dead interval
# (4 s here), and traffic keeps flowing; when the link returns, both
# paths come back.
class TestFrrEcmp < Test::Unit::TestCase
  def setup
    ok, why = FrrLab.available?
    omit(why) unless ok
    @t = FrrTopology.new("ecmp#{Process.pid % 1000}")
    @t.core('r1', '1.1.1.1', fib: true)
    @t.frr('r2', '2.2.2.2')
    @t.link('r1', 'r2', '10.0.12.0/30', p2p: true)
    @t.link('r1', 'r2', '10.0.12.4/30', p2p: true)
    @t.start
  end

  def teardown
    @t&.stop
  end

  def kernel_route = @t.run_in('r1', 'ip', 'route', 'show', '2.2.2.2').first
  def hops = kernel_route.scan(/via (\S+) dev (\S+)/)
  def ping = @t.run_in('r1', 'ping', '-c', '1', '-W', '1', '-I', '1.1.1.1', '2.2.2.2').last

  def test_failover_and_back
    assert @t.wait_for(60) { hops.size == 2 }, kernel_route
    assert_equal [%w[10.0.12.2 r2a], %w[10.0.12.6 r2b]], hops.sort
    assert @t.wait_for(10) { ping }

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @t.run_in('r2', 'ip', 'link', 'set', 'r1a', 'down')
    assert @t.wait_for(15) { hops == [%w[10.0.12.6 r2b]] }, kernel_route
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    assert_operator took, :<, 8, format('failover took %.1f s', took)
    assert ping, 'traffic on the remaining path'

    @t.run_in('r2', 'ip', 'link', 'set', 'r1a', 'up')
    assert @t.wait_for(30) { hops.size == 2 }, kernel_route
    assert ping
  end
end
