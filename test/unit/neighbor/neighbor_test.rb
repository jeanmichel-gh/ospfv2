require "test/unit"
require 'stringio'
require 'ospfv2'
require_relative '../../support/capture_transport'

class TestNeighborNeighbor < Test::Unit::TestCase
  include OSPFv2

  def new_neighbor(**opts)
    Neighbor.new({ log: StringIO.new }.merge(opts))
  end

  def test_states
    assert_equal :down, new_neighbor.state
    assert new_neighbor.in_state?(:down)
    assert !new_neighbor.in_state?(:full)
    assert new_neighbor.in_state?(:full, :down)
  end

  def test_does_not_shadow_object_send
    n = new_neighbor
    assert_equal :down, n.send(:state)
    assert_equal Kernel.instance_method(:send).owner, n.method(:send).owner
  end

  def test_options
    n = new_neighbor(router_id: '9.9.9.9', area_id: '0.0.0.7', src_addr: '10.1.2.3/26',
                     hello_interval: 3)
    assert_equal '9.9.9.9', n.router_id.to_ip
    assert_equal '0.0.0.7', n.area_id.to_ip
    assert_equal '10.1.2.3', n.address
    assert_equal '255.255.255.192', n.netmask
    assert_equal 3, n.hello_int
    assert_equal 12, n.dead_int
  end

  def test_hello_carries_configured_parameters
    n = new_neighbor(router_id: 1, area_id: 5, src_addr: '10.0.0.1/30', hello_interval: 2, dead_interval: 7)
    h = n.hello
    assert_equal 2, h.hello_interval
    assert_equal 7, h.router_dead_interval
    assert_equal '255.255.255.252', h.netmask.to_ip
    assert_equal 5, h.area_id.to_i
  end

  def test_flood
    t = CaptureTransport.new
    n = new_neighbor(transport: t, hello_interval: 60)
    n.start
    t.sent.clear
    lsas = [Router.new(advertising_router: 1, ls_id: 1), Router.new(advertising_router: 2, ls_id: 2)]
    n.flood(lsas)
    assert_equal 1, t.sent.size
    pkt, dest = t.sent.first
    assert_instance_of LinkStateUpdate, pkt
    assert_equal '224.0.0.6', dest, 'a DROther floods to AllDRouters on broadcast'
    assert_equal 2, pkt.lsas.size
  ensure
    n&.stop
  end

  def test_flood_on_point_to_point_goes_to_all_spf_routers
    t = CaptureTransport.new
    n = new_neighbor(transport: t, hello_interval: 60, network_type: :p2p)
    n.start
    t.sent.clear
    n.flood(Router.new(advertising_router: 1, ls_id: 1))
    assert_equal '224.0.0.5', t.sent.first.last
  ensure
    n&.stop
  end

  def test_flood_splits_large_updates
    t = CaptureTransport.new
    n = new_neighbor(transport: t, hello_interval: 60)
    n.start
    t.sent.clear
    lsas = (1..200).map { |i| Summary.new(advertising_router: 1, ls_id: i << 8, netmask: 0xffffff00) }
    n.flood(lsas)
    assert t.sent.size > 1
    assert_equal 200, t.sent.sum { |p, _| p.lsas.size }
    t.sent.each { |p, _| assert p.encode.bytesize <= 1500 }
  ensure
    n&.stop
  end

  def test_rejects_hello_with_mismatched_interval
    t = CaptureTransport.new
    log = StringIO.new
    n = Neighbor.new(transport: t, log: log, hello_interval: 10, src_addr: '10.0.0.1/24')
    n.start
    bad = Hello.new(router_id: 2, netmask: '255.255.255.0', hello_interval: 5, router_dead_interval: 20)
    t.inject(bad, '10.0.0.2')
    sleep 0.2
    assert_equal :attempt, n.state
    assert_match(/hello interval 5 != 10/, log.string)
  ensure
    n&.stop
  end

  def test_rejects_packet_from_other_area
    t = CaptureTransport.new
    log = StringIO.new
    n = Neighbor.new(transport: t, log: log, area_id: 1, src_addr: '10.0.0.1/24')
    n.start
    t.inject(Hello.new(router_id: 2, area_id: 0, netmask: '255.255.255.0'), '10.0.0.2')
    sleep 0.2
    assert_equal :attempt, n.state
    assert_match(/area 0.0.0.0 != 0.0.0.1/, log.string)
  ensure
    n&.stop
  end

  def test_packet_sanity_checks
    good = Hello.new(router_id: 2, netmask: '255.255.255.0').encode
    assert_nil NeighborEventHandler.invalid?(good)
    assert_nil NeighborEventHandler.invalid?(good + "\xff\xff\x00\x0c".b), 'trailing LLS data is fine'
    bad = good.dup
    bad.setbyte(30, bad.getbyte(30) ^ 0x10)
    assert_equal 'bad checksum', NeighborEventHandler.invalid?(bad)
    assert_match(/version/, NeighborEventHandler.invalid?("\x03".b + good[1..]))
    assert_match(/length/, NeighborEventHandler.invalid?(good[0, 30]))
  end

  def test_corrupt_hello_is_dropped
    t = CaptureTransport.new
    log = StringIO.new
    n = Neighbor.new(transport: t, log: log, src_addr: '10.0.0.1/24')
    n.start
    bytes = Hello.new(router_id: 2, netmask: '255.255.255.0').encode
    bytes.setbyte(30, bytes.getbyte(30) ^ 0x10)
    t.instance_variable_get(:@on_packet).call(bytes, '10.0.0.2')
    sleep 0.2
    assert_equal :attempt, n.state
    assert_match(/bad checksum/, log.string)
  ensure
    n&.stop
  end

  def test_hello_moves_to_init_then_exstart
    t = CaptureTransport.new
    n = new_neighbor(transport: t, router_id: 1, src_addr: '10.0.0.1/24')
    states = []
    n.on_state_change { |_old, new, _ev| states << new }
    n.start
    t.inject(Hello.new(router_id: 2, netmask: '255.255.255.0'), '10.0.0.2')
    sleep 0.2
    hello = Hello.new(router_id: 2, netmask: '255.255.255.0')
    hello.neighbors = 1
    t.inject(hello, '10.0.0.2')
    sleep 0.2
    assert_include states, :exstart
    assert_equal '10.0.0.2', n.neighbor_ip
    dd = t.packets(DatabaseDescription).last
    assert dd, 'expected a DD in ExStart'
    assert_equal 7, dd.imms
  ensure
    n&.stop
  end
end
