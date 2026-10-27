# frozen_string_literal: true

require 'test/unit'
require 'socket'
require 'ospfv2/fib/netlink'

# Fib::Netlink without touching the kernel table: encoding only. Opening a
# netlink socket needs no privilege.
class TestFibNetlinkEncoding < Test::Unit::TestCase
  def setup
    omit('Linux only') unless RUBY_PLATFORM.include?('linux')
    @calls = 0
    @nl = OSPFv2::Fib::Netlink.new(links: lambda {
      @calls += 1
      { 'eth1' => 3 }
    })
  end

  def teardown
    @nl&.close
  end

  def route(i) = OSPFv2::Fib::Route.new((20 << 24) | (i << 8), 24, [['eth1', 0x0a090002]], 20)

  def test_the_interface_map_is_read_once_not_per_route
    1000.times { |i| @nl.send(:encode, route(i), hops: true) }
    assert_equal 1, @calls
  end

  def test_an_unknown_interface_refreshes_the_map_once
    r = OSPFv2::Fib::Route.new(0, 0, [['eth9', 1]], 20)
    assert_raise(OSPFv2::Fib::Error) { @nl.send(:encode, r, hops: true) }
    assert_equal 2, @calls
  end


  def test_kernel_reserved_protocol_ids_are_refused
    assert_raise(ArgumentError) { OSPFv2::Fib::Netlink.new(protocol: 2) }
  end
end
