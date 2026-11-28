# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'ospfv2/daemon/system'

# System#mpls against a /proc/sys/net/mpls of its own.
class TestSystemMpls < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir('mpls')
    FileUtils.mkdir_p(File.join(@dir, 'conf', 'eth1'))
    File.write(File.join(@dir, 'conf', 'eth1', 'input'), "0\n")
    @sys = OSPFv2::Daemon::System.new
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_input_on_and_the_table_large_enough
    File.write(File.join(@dir, 'platform_labels'), "100000\n")
    assert_nil @sys.mpls(%w[eth1 eth9], highest: 23_999, proc_mpls: @dir)
    assert_equal "1\n", File.read(File.join(@dir, 'conf', 'eth1', 'input'))
  end

  def test_a_table_too_small
    File.write(File.join(@dir, 'platform_labels'), "20000\n")
    assert_equal 'net.mpls.platform_labels is 20000, and labels go up to 23999', @sys.mpls(%w[eth1], highest: 23_999, proc_mpls: @dir)
    assert_equal "0\n", File.read(File.join(@dir, 'conf', 'eth1', 'input')), 'nothing written'
  end

  def test_no_module
    assert_match(/platform_labels is missing: is the mpls_router module loaded\?/, @sys.mpls(%w[eth1], highest: 1, proc_mpls: @dir))
  end
end
