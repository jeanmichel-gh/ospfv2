# frozen_string_literal: true

require 'test/unit'
require 'support/core_lab'

# Adjacencies, database exchange and flooding, on a fake clock.
class TestCoreAdjacency < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  def setup
    @lab = CoreLab.new
  end

  def external(i, advr: '7.7.7.7', seq: Lsa::INITIAL_SEQ, age: 0)
    body = [0xffffff00, 0x8000_0000 | 20, 0, 0].pack('NNNN')
    Lsa.build(type: 5, ls_id: (50 << 24) + (i << 8), advr: advr, seq: seq, body: body, age: age)
  end

  def p2p_pair(**opts)
    seg = @lab.segment
    a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', { type: :p2p, **opts }], [:passive, '1.1.1.1/32'])
    b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', { type: :p2p, **opts }], [:passive, '2.2.2.2/32'])
    [seg, a, b]
  end

  def test_point_to_point_reaches_full_and_syncs
    _, a, b = p2p_pair
    @lab.start
    took = @lab.run_until(60) { @lab.full?(a, b) }
    assert_operator took, :<, 25
    @lab.converge([a, b])

    links = @lab.lsa(a, 1, '1.1.1.1').router_links.map { |l| [l.type_name, Addr.to_s(l.id), l.metric] }
    assert_equal [[:p2p, '2.2.2.2', 10], [:stub, '10.0.12.0', 10], [:stub, '1.1.1.1', 10]].sort, links.sort
    assert_nil @lab.lsa(a, 2, '10.0.12.1'), 'no network-LSA on p2p'
  end

  def test_broadcast_two_routers
    lan = @lab.segment
    a = @lab.router('1.1.1.1', [lan, '10.0.0.1/24'])
    b = @lab.router('2.2.2.2', [lan, '10.0.0.2/24'])
    @lab.start
    @lab.run_until(120) { @lab.full?(a, b) && a.interfaces['eth0'].state == :backup }
    @lab.converge([a, b])
    assert_equal :dr, b.interfaces['eth0'].state
    assert_equal :backup, a.interfaces['eth0'].state
    assert @lab.synced?(a, b)

    net = @lab.lsa(a, 2, '10.0.0.2', '2.2.2.2')
    assert net, 'DR originates the network-LSA'
    mask, routers = net.network_body
    assert_equal 24, Addr.prefix_len(mask)
    assert_equal %w[1.1.1.1 2.2.2.2], routers.map { |r| Addr.to_s(r) }.sort
    link = @lab.lsa(a, 1, '1.1.1.1').router_links.first
    assert_equal [:transit, '10.0.0.2', '10.0.0.1'], [link.type_name, Addr.to_s(link.id), Addr.to_s(link.data)]
  end

  def test_large_database_is_paged_and_requested_in_batches
    _, a, b = p2p_pair
    lsas = Array.new(3000) { |i| external(i) }
    lsas.each { |l| a.as_lsdb.install(l) }
    dds = 0
    lsrs = 0
    b.interfaces['eth0'].transport.hub.drop_if do |bytes, from, _|
      type = bytes.getbyte(1)
      dds += 1 if type == 2 && from == '10.0.12.1'
      lsrs += 1 if type == 3 && from == '10.0.12.2'
      false
    end
    @lab.start
    @lab.run_until(120) { @lab.full?(a, b) }
    assert_equal 3000, b.as_lsdb.size
    @lab.converge([a, b])
    assert_operator dds, :>, 3000 / 72, 'the summary took several DD pages'
    assert_operator lsrs, :>, 3000 / 123, 'requests were split to fit the MTU'
  end

  def test_slave_with_more_to_send_than_the_master
    _, a, b = p2p_pair
    800.times { |i| b.as_lsdb.install(external(i, advr: '8.8.8.8')) }
    5.times { |i| a.as_lsdb.install(external(1000 + i)) }
    @lab.start
    @lab.converge([a, b])
    assert_equal 805, a.as_lsdb.size
  end

  def test_converges_through_packet_loss
    seg, a, b = p2p_pair
    400.times { |i| a.as_lsdb.install(external(i)) }
    rng = Random.new(42)
    seg.drop_if { |_bytes, _from, _dest| rng.rand < 0.25 }
    @lab.start
    @lab.run_until(600) { @lab.full?(a, b) && b.as_lsdb.size == 400 }
    seg.drop_if { false }
    @lab.converge([a, b], timeout: 30)
  end

  def test_flooding_a_change_through_a_chain
    s1 = @lab.segment
    s2 = @lab.segment
    a = @lab.router('1.1.1.1', [s1, '10.0.1.1/30', { type: :p2p }])
    b = @lab.router('2.2.2.2', [s1, '10.0.1.2/30', { type: :p2p }], [s2, '10.0.2.1/30', { type: :p2p }])
    c = @lab.router('3.3.3.3', [s2, '10.0.2.2/30', { type: :p2p }])
    @lab.start
    @lab.converge([a, b, c], adjacent: [[a, b], [b, c]])

    a.add_interface(name: 'lo9', address: '192.168.99.1/32', passive: true)
    took = @lab.run_until(10) do
      @lab.lsa(c, 1, '1.1.1.1').router_links.any? { |l| Addr.to_s(l.id) == '192.168.99.1' }
    end
    assert_operator took, :<, 1, 'a change crosses two hops at once'
    @lab.converge([a, b, c], adjacent: [[a, b], [b, c]])
  end

  def test_dead_neighbor_is_detected_and_the_link_withdrawn
    seg, a, b = p2p_pair
    @lab.start
    @lab.run_until(60) { @lab.full?(a, b) }
    @lab.advance(6)
    seg.drop_if { |_, from, _| from == '10.0.12.2' } # B goes silent
    t = @lab.run_until(60) { a.neighbors.empty? }
    assert_in_delta 40, t, 11
    @lab.advance(6)
    types = @lab.lsa(a, 1, '1.1.1.1').router_links.map(&:type_name)
    assert_not_include types, :p2p
    assert_match(/InactivityTimer/, @lab.log.grep(/1\.1\.1\.1 .*full -> down/).first.to_s)
  end

  def test_hello_mismatch_keeps_neighbors_apart
    seg = @lab.segment
    a = @lab.router('1.1.1.1', [seg, '10.0.0.1/24', { hello_interval: 10 }])
    b = @lab.router('2.2.2.2', [seg, '10.0.0.2/24', { hello_interval: 5 }])
    c = @lab.router('3.3.3.3', [seg, '10.0.0.3/25', { hello_interval: 10 }])
    @lab.start
    @lab.advance(60)
    assert a.neighbors.empty?
    assert b.neighbors.empty?
    assert c.neighbors.empty?
    assert_operator a.interfaces['eth0'].stats[:drop_hello], :>, 0
    assert @lab.log.any? { |l| l.include?('hello interval 5') }
    assert @lab.log.any? { |l| l.include?('netmask 255.255.255.128') }
  end

  def test_area_mismatch_is_dropped
    seg = @lab.segment
    a = @lab.router('1.1.1.1', [seg, '10.0.0.1/24'])
    b = @lab.router('2.2.2.2')
    b.add_interface(name: 'eth0', address: '10.0.0.2/24', area: '0.0.0.1',
                    transport: Transport::Loopback.new(seg, '10.0.0.2'))
    @lab.start
    @lab.advance(30)
    assert a.neighbors.empty?
    assert @lab.log.any? { |l| l.include?('area 0.0.0.1') }
  end

  def test_mtu_mismatch_stops_in_exstart
    seg = @lab.segment
    a = @lab.router('1.1.1.1', [seg, '10.0.0.1/30', { type: :p2p, mtu: 1500 }])
    b = @lab.router('2.2.2.2', [seg, '10.0.0.2/30', { type: :p2p, mtu: 9000 }])
    @lab.start
    @lab.advance(60)
    assert_equal :exstart, @lab.neighbor(a, '2.2.2.2').state
    assert @lab.log.any? { |l| l.include?('MTU mismatch') }

    a.interfaces['eth0'].mtu_ignore = true
    @lab.run_until(30) { @lab.full?(a, b) }
  end

  def test_restarted_router_takes_over_its_own_lsas
    _, a, b = p2p_pair
    @lab.start
    @lab.run_until(60) { @lab.full?(a, b) }
    # Push A's router-LSA sequence number up.
    5.times do |i|
      a.add_interface(name: "lo#{10 + i}", address: "172.16.#{i}.1/32", passive: true)
      @lab.advance(6)
    end
    before = @lab.lsa(b, 1, '1.1.1.1')
    assert_operator before.seq, :>, Lsa::INITIAL_SEQ + 4

    a.stop
    a2 = @lab.router('1.1.1.1', [a.interfaces['eth0'].transport.hub, '10.0.12.1/30', { type: :p2p }], start: true)
    @lab.run_until(60) { @lab.full?(a2, b) }
    @lab.advance(8)
    after = @lab.lsa(b, 1, '1.1.1.1')
    assert_operator after.seq, :>, before.seq, 'the new instance jumped past the old one'
    assert_equal @lab.lsa(a2, 1, '1.1.1.1').seq, after.seq
    stubs = after.router_links.map { |l| Addr.to_s(l.id) }
    assert_not_include stubs, '172.16.0.1', 'stale links are gone'
  end

  def test_lsas_are_refreshed_and_never_reach_max_age
    _, a, b = p2p_pair
    @lab.start
    @lab.converge([a, b])
    seq0 = @lab.lsa(b, 1, '1.1.1.1').seq
    @lab.advance(OSPFv2::LSRefreshTime + 5)
    assert_equal seq0 + 1, @lab.lsa(b, 1, '1.1.1.1').seq
    @lab.advance(OSPFv2::MaxAge)
    assert @lab.full?(a, b)
    assert b.database.none? { |_, l| l.max_age? }
    assert_operator @lab.lsa(b, 1, '1.1.1.1').age, :<, OSPFv2::LSRefreshTime
  end

  def test_orphan_lsa_ages_out_and_is_removed_everywhere
    _, a, b = p2p_pair
    a.as_lsdb.install(external(1, age: OSPFv2::MaxAge - 300))
    @lab.start
    @lab.run_until(60) { @lab.full?(a, b) && b.as_lsdb.size == 1 }
    @lab.advance(330)
    assert_equal 0, a.as_lsdb.size
    assert_equal 0, b.as_lsdb.size
    assert @lab.log.any? { |l| l.include?('reached MaxAge') }
  end

  def test_bad_lsa_checksum_is_dropped
    _, a, b = p2p_pair
    @lab.start
    @lab.run_until(60) { @lab.full?(a, b) }
    bad = external(5).bytes.dup
    bad[30] = (bad.getbyte(30) ^ 1).chr
    nbr = @lab.neighbor(b, '1.1.1.1')
    b.receive_update(nbr, Wire::LinkStateUpdate.new(lsas: [Lsa.new(bad)]))
    assert_equal 0, b.as_lsdb.size
    assert_equal 1, b.interfaces['eth0'].stats[:drop_lsa]
  end
end
