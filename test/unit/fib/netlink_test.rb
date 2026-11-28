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


  # ---- SR-MPLS: what iproute2 6.19 sends, captured with strace -e
  # write=all in a network namespace on ospflab (2026-11-28), v0 index 3,
  # v1 index 5, lo 1, header (16 octets) removed. The commands:
  IPROUTE2 = {
    # ip -M route add 16004 as 17004 via inet 10.0.12.2 dev v0 proto 89
    swap: '1c140000fe590001000000000800010003e84100080013000426c1000a00120002000a000c0200000800040003000000',
    # ip -M route add 16002 via inet 10.0.12.2 dev v0 proto 89
    php: '1c140000fe590001000000000800010003e821000a00120002000a000c0200000800040003000000',
    # ip -M route add 16001 dev lo proto 89
    lookup: '1c140000fe590001000000000800010003e811000800040001000000',
    # ip -M route add 16005 proto 89 nexthop as 17005 via inet 10.0.12.2 dev v0 nexthop as 18005 via inet 10.0.13.2 dev v1
    mswap: '1c140000fe590001000000000800010003e851003c0009001c00000003000000080013000426d1000a00120002000a000c020000' \
           '1c0000000500000008001300046551000a00120002000a000d020000',
    # ip -M route del 16004 proto 89
    del: '1c140000fe590001000000000800010003e84100',
    # ip route add 10.255.0.4/32 encap mpls 17004 via 10.0.12.2 dev v0 proto 89 metric 20
    push: '02200000fe59000100000000080001000aff00040c001680080001000426c1000600150001000000080005000a000c02' \
          '08000600140000000800040003000000',
    # ip route add 10.255.0.5/32 proto 89 metric 20 nexthop encap mpls 17005 via 10.0.12.2 dev v0
    #   nexthop encap mpls 18005 via 10.0.13.2 dev v1
    multi: '02200000fe59000100000000080001000aff000508000600140000004c00090024000000030000000c001680080001000426d100' \
           '0600150001000000080005000a000c0224000000050000000c00168008000100046551000600150001000000080005000a000d02'
  }.transform_values { [_1].pack('H*') }

  A = ->(s) { OSPFv2::Core::Addr.to_i(s) }
  F = OSPFv2::Fib

  def mpls
    OSPFv2::Fib::Netlink.new(protocol: 89, links: -> { { 'v0' => 3, 'v1' => 5, 'lo' => 1 } })
  end

  # Label routes: the same octets as iproute2's.
  def test_label_routes_are_iproute2_s
    nl = mpls
    {
      swap: F::Label.new(16_004, [['v0', A['10.0.12.2'], 17_004]]),
      php: F::Label.new(16_002, [['v0', A['10.0.12.2'], nil]]),
      lookup: F::Label.new(16_001, [['lo', nil, nil]]),
      mswap: F::Label.new(16_005, [['v0', A['10.0.12.2'], 17_005], ['v1', A['10.0.13.2'], 18_005]])
    }.each { |name, l| assert_equal IPROUTE2[name].unpack1('H*'), nl.send(:encode_label, l, hops: true).unpack1('H*'), name.to_s }
    assert_equal IPROUTE2[:del].unpack1('H*'), nl.send(:encode_label, F::Label.new(16_004, []), hops: false).unpack1('H*')
  ensure
    nl&.close
  end

  # A pushed label on an IP route: iproute2's rtmsg and attributes, in
  # ospfd's order and with its RTA_TABLE, which the kernel takes the same.
  def test_a_push_is_iproute2_s
    nl = mpls
    attrs = ->(b) { nl.send(:attrs, b.byteslice(12..)).except(OSPFv2::Fib::Netlink::RTA_TABLE) }
    one = F::Route.new(A['10.255.0.4'], 32, [['v0', A['10.0.12.2'], 17_004]], 20)
    ours = nl.send(:encode, one, hops: true)
    assert_equal IPROUTE2[:push].byteslice(0, 12), ours.byteslice(0, 12)
    assert_equal attrs.(IPROUTE2[:push]), attrs.(ours)
    two = F::Route.new(A['10.255.0.5'], 32, [['v0', A['10.0.12.2'], 17_005], ['v1', A['10.0.13.2'], 18_005]], 20)
    ours = nl.send(:encode, two, hops: true)
    assert_equal attrs.(IPROUTE2[:multi]), attrs.(ours)
    assert_equal IPROUTE2[:multi].unpack1('H*').match(/4c000900(.*)\z/)[1], ours.unpack1('H*').match(/4c000900(.*)\z/)[1],
                 'each nexthop: its encap, then its gateway'
  ensure
    nl&.close
  end

  def test_implicit_null_pushes_nothing
    nl = mpls
    a = nl.send(:encode, F::Route.new(A['10.255.0.2'], 32, [['v0', A['10.0.12.2'], 3]], 20), hops: true)
    b = nl.send(:encode, F::Route.new(A['10.255.0.2'], 32, [['v0', A['10.0.12.2']]], 20), hops: true)
    assert_equal b, a
  ensure
    nl&.close
  end

  # What the kernel dumps back reads as what was sent.
  def test_decoding_reads_back
    nl = mpls
    names = { 3 => 'v0', 5 => 'v1', 1 => 'lo' }
    assert_equal F::Label.new(16_005, [['v0', A['10.0.12.2'], 17_005], ['v1', A['10.0.13.2'], 18_005]]),
                 nl.send(:decode_label, IPROUTE2[:mswap], names)
    assert_equal F::Label.new(16_002, [['v0', A['10.0.12.2'], nil]]), nl.send(:decode_label, IPROUTE2[:php], names)
    r = nl.send(:decode, IPROUTE2[:push], names, [89])
    assert_equal [['v0', A['10.0.12.2'], 17_004]], r.next_hops
    r = nl.send(:decode, IPROUTE2[:multi], names, [89])
    assert_equal [['v0', A['10.0.12.2'], 17_005], ['v1', A['10.0.13.2'], 18_005]], r.next_hops
  ensure
    nl&.close
  end

  def test_kernel_reserved_protocol_ids_are_refused
    assert_raise(ArgumentError) { OSPFv2::Fib::Netlink.new(protocol: 2) }
  end
end
