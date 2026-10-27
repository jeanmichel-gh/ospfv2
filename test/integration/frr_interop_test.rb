# frozen_string_literal: true

require 'test/unit'
require 'support/frr_lab'

# The core router against FRRouting's ospfd over real raw sockets, one
# network namespace each. Opt in with OSPFV2_FRR=1 as root with FRR
# installed (CI does this in its interop job):
#
#   sudo OSPFV2_FRR=1 ruby -Ilib -Itest test/integration/frr_interop_test.rb
class TestFrrInterop < Test::Unit::TestCase
  MD5 = ['ip ospf authentication message-digest', 'ip ospf message-digest-key 1 md5 secret'].freeze
  EXPECTED_LSDB = [[1, '1.1.1.1', '1.1.1.1'], [1, '2.2.2.2', '2.2.2.2']].freeze

  def setup
    ok, why = FrrLab.available?
    omit(why) unless ok
    @lab = FrrLab.new("ospfv2-#{Process.pid % 1000}-#{name.hash.abs % 1000}")
  end

  def teardown
    @lab&.stop
  end

  def full_both_ways
    @lab.wait_for(30) { @lab.frr_neighbor_state == 'Full' && @lab.core_neighbor_state == 'full' }
  end

  def assert_synced(network_lsa)
    expected = EXPECTED_LSDB + (network_lsa ? [[2, '10.0.12.2', '2.2.2.2']] : [])
    ok = @lab.wait_for(20) { @lab.core_lsdb == expected.sort && @lab.frr_lsdb == expected.sort }
    assert ok, "core #{@lab.core_lsdb.inspect}\nfrr  #{@lab.frr_lsdb.inspect}\n#{@lab.core_log.lines.last(20).join}"
  end

  def assert_full
    assert full_both_ways, "frr #{@lab.frr_neighbor_state.inspect}, core #{@lab.core_neighbor_state.inspect}\n" \
                           "#{@lab.core_log.lines.last(20).join}"
  end

  def test_broadcast_without_authentication
    @lab.start
    assert_full
    assert_synced(true)
  end

  def test_point_to_point_without_authentication
    @lab.start(p2p: true)
    assert_full
    assert_synced(false)
  end

  def test_md5
    @lab.start(frr_interface: MD5, core_interface: { auth: { type: 'md5', keys: { '1' => 'secret' } } })
    assert_full
    assert_synced(true)
    assert_equal 0, @lab.core_stat(:drop_auth)
    assert_match(/Algorithm:MD5/, @lab.vtysh('show ip ospf interface veth0'))
  end

  def test_md5_wrong_key
    @lab.start(frr_interface: MD5, core_interface: { auth: { type: 'md5', keys: { '1' => 'wrong' } } })
    sleep 8
    assert_nil @lab.frr_neighbor_state
    assert_nil @lab.core_neighbor_state
    assert_operator @lab.core_stat(:drop_auth), :>, 3
    assert_match(/digest mismatch/, @lab.core_log)
  end

  def test_md5_two_keys
    # FRR 8.4 signs with its newest key and checks what it receives
    # against that key only, whatever key ID the packet names. RFC 2328 D.3
    # asks receivers to accept every valid key, which we do; so during a
    # rollover with FRR, move both sides to the new send key together.
    @lab.start(frr_interface: MD5 + ['ip ospf message-digest-key 2 md5 newer'],
               core_interface: { auth: { type: 'md5', keys: { '1' => 'secret', '2' => 'newer' } } })
    assert_full
    assert_synced(true)
  end

  def test_simple_password
    @lab.start(frr_interface: ['ip ospf authentication', 'ip ospf authentication-key pw'],
               core_interface: { auth: { type: 'simple', password: 'pw' } })
    assert_full
    assert_synced(true)
  end
end
