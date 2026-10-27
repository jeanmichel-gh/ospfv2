# frozen_string_literal: true

require 'test/unit'
require 'json'
require 'open3'

# Fib::Netlink against a real kernel table, in a throwaway network
# namespace. Needs root and iproute2:
#
#   sudo ruby -Ilib -Itest test/integration/netlink_test.rb
class TestFibNetlink < Test::Unit::TestCase
  ROOT = File.expand_path('../..', __dir__)

  def setup
    omit('needs root for network namespaces') unless Process.uid.zero?
    omit('needs iproute2') unless system('which ip > /dev/null')
    @ns = "nl#{Process.pid % 10_000}"
    sh "ip netns add #{@ns}"
    sh "ip -n #{@ns} link set lo up"
    { 'eth1' => '10.9.0.1/24', 'eth2' => '10.9.1.1/24' }.each do |dev, addr|
      sh "ip -n #{@ns} link add #{dev} type veth peer name #{dev}x"
      sh "ip -n #{@ns} addr add #{addr} dev #{dev}"
      sh "ip -n #{@ns} link set #{dev}x up"
      sh "ip -n #{@ns} link set #{dev} up"
    end
  end

  def teardown
    system("ip netns del #{@ns} 2>/dev/null") if @ns
  end

  def sh(cmd) = system(cmd) || raise("failed: #{cmd}")

  def probe(ops, **opts)
    out, err, st = Open3.capture3({ 'NETLINK_OPTS' => JSON.generate(opts) }, 'ip', 'netns', 'exec', @ns,
                                  RbConfig.ruby, "-I#{ROOT}/lib", "#{ROOT}/test/support/netlink_probe.rb",
                                  JSON.generate(ops))
    assert st.success?, err
    out.lines.map { |l| JSON.parse(l) }
  end

  # What iproute2 sees, one line per route.
  def kernel(proto = 89)
    `ip -n #{@ns} route show proto #{proto} table all`.lines.map(&:strip).reject(&:empty?)
  end

  def test_replace_dump_and_delete
    r = probe([['replace', '10.1.0.0/16', [%w[eth1 10.9.0.2]], 20],
               ['replace', '0.0.0.0/0', [%w[eth2 10.9.1.2]], 20],
               ['dump']])
    assert_equal [{ 'ok' => true }, { 'ok' => true }], r[0, 2]
    assert_equal ['0.0.0.0/0 via 10.9.1.2 eth2 metric 20', '10.1.0.0/16 via 10.9.0.2 eth1 metric 20'], r[2]['routes']
    assert_include kernel, '10.1.0.0/16 via 10.9.0.2 dev eth1 metric 20'
    assert_include kernel, 'default via 10.9.1.2 dev eth2 metric 20'

    r = probe([['replace', '10.1.0.0/16', [%w[eth2 10.9.1.3]], 20], ['dump']])
    assert_equal ['0.0.0.0/0 via 10.9.1.2 eth2 metric 20', '10.1.0.0/16 via 10.9.1.3 eth2 metric 20'], r[1]['routes'],
                 'replace changes the route in place'

    r = probe([['delete', '10.1.0.0/16', [], 20], ['delete', '10.1.0.0/16', [], 20], ['dump']])
    assert_equal [{ 'ok' => true }, { 'ok' => true }], r[0, 2], 'deleting a route that is gone is fine'
    assert_equal ['0.0.0.0/0 via 10.9.1.2 eth2 metric 20'], r[2]['routes']
  end

  def test_multipath
    r = probe([['replace', '10.2.0.0/16', [%w[eth1 10.9.0.2], %w[eth2 10.9.1.2]], 20], ['dump']])
    assert_equal({ 'ok' => true }, r[0])
    assert_equal ['10.2.0.0/16 via 10.9.0.2 eth1, via 10.9.1.2 eth2 metric 20'], r[1]['routes']
    route = `ip -n #{@ns} route show 10.2.0.0/16`
    assert_match(/nexthop via 10\.9\.0\.2 dev eth1 weight 1/, route)
    assert_match(/nexthop via 10\.9\.1\.2 dev eth2 weight 1/, route)
  end

  def test_only_our_routes_are_seen_or_touched
    sh "ip -n #{@ns} route add 10.3.0.0/16 via 10.9.0.2 proto 188 metric 20"   # FRR's ospfd
    sh "ip -n #{@ns} route add 10.4.0.0/16 via 10.9.0.2 metric 20"             # static
    r = probe([['dump'], ['delete', '10.3.0.0/16', [], 20], ['delete', '10.4.0.0/16', [], 20]])
    assert_equal [], r[0]['routes']
    assert_equal 1, kernel(188).size, 'a route of another protocol is not deleted'
    assert_match(/10\.4\.0\.0/, `ip -n #{@ns} route show 10.4.0.0/16`)
  end

  def test_two_metrics_are_two_routes
    probe([['replace', '10.5.0.0/16', [%w[eth1 10.9.0.2]], 20], ['replace', '10.5.0.0/16', [%w[eth1 10.9.0.2]], 100]])
    assert_equal 2, kernel.count { |l| l.start_with?('10.5.0.0/16') }
    r = probe([['delete', '10.5.0.0/16', [], 20], ['dump']])
    assert_equal ['10.5.0.0/16 via 10.9.0.2 eth1 metric 100'], r[1]['routes']
  end

  def test_other_table_and_protocol
    r = probe([['replace', '10.6.0.0/16', [%w[eth1 10.9.0.2]], 20], ['dump']], protocol: 200, table: 1000)
    assert_equal ['10.6.0.0/16 via 10.9.0.2 eth1 metric 20'], r[1]['routes']
    assert_match(/10\.6\.0\.0\/16 via 10\.9\.0\.2 dev eth1 metric 20/, `ip -n #{@ns} route show table 1000 proto 200`)
    assert_empty probe([['dump']])[0]['routes'], 'table 254, protocol 89 sees none of it'
  end

  def test_kernel_errors_come_back_as_messages
    r = probe([['replace', '10.7.0.0/16', [%w[eth1 192.0.2.1]], 20],
               ['replace', '10.7.0.0/16', [%w[nosuch 10.9.0.2]], 20]])
    assert_match(/unreachable|invalid/i, r[0]['error'])
    assert_equal 'no interface nosuch', r[1]['error']
  end
end
