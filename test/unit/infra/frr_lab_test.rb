# frozen_string_literal: true

require 'test/unit'
require_relative '../../support/frr_lab'

# The FRR interop tests start FRR's daemons in pathspaces. Ubuntu 26.04
# enforces an AppArmor profile for ospfd that denies a pathspace's pid
# file, and ospfd exits at start. The lab says so when it fails.
class TestFrrLab < Test::Unit::TestCase
  PROFILES = <<~TXT
    ospf6d (enforce)
    ospfd (enforce)
    isisd (complain)
    /usr/lib/frr/zebra (enforce)
    nvidia_modprobe (enforce)
  TXT

  def test_the_daemons_an_enforced_profile_confines
    assert_equal %w[ospfd zebra], FrrLab.apparmor_enforced(%w[ospfd zebra isisd bgpd], PROFILES)
    assert_equal [], FrrLab.apparmor_enforced(%w[ospfd], '')
    assert_equal [], FrrLab.apparmor_enforced(%w[ospf], PROFILES), 'a name is matched whole'
  end

  def test_a_failure_names_the_profile_when_one_is_enforced
    msg = FrrLab.failure_message('ip netns exec x /usr/lib/frr/ospfd -N x', 'ospfd',
                                 "Can't create pid lock file /var/run/frr/x/ospfd.pid (Permission denied), exiting\n", ['ospfd'])
    assert_match(/\Afailed: ip netns exec x/, msg)
    assert_match(/Permission denied/, msg)
    assert_match(%r{sudo apparmor_parser -R /etc/apparmor.d/ospfd}, msg)
  end

  def test_a_failure_without_a_profile_is_only_the_command_and_its_output
    assert_equal "failed: cmd\nboom", FrrLab.failure_message('cmd', 'zebra', "boom\n", [])
    assert_equal 'failed: cmd', FrrLab.failure_message('cmd', 'zebra', '', [])
  end
end
