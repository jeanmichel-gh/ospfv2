# frozen_string_literal: true

require 'test/unit'
require 'timeout'
require 'support/core_lab'

# Regression tests for the issues an independent RFC 2328 review found in
# the first version of the core. One test per finding, most serious first.
class TestCoreReviewFixes < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  def setup
    @lab = CoreLab.new
  end

  def capture(seg)
    sent = []
    seg.drop_if do |bytes, from, dest|
      sent << [@lab.loop.now, from, dest, bytes.getbyte(1), bytes]
      false
    end
    sent
  end

  # 1. A 28-byte update claiming 2**32-1 LSAs must not allocate them.
  def test_lsu_count_cannot_size_an_allocation
    raw = Wire.encode(Wire::LinkStateUpdate.new(lsas: []), router_id: 1, area_id: 0)
    raw[24, 4] = [0xffff_ffff].pack('N')
    raw[12, 2] = "\0\0"
    raw[12, 2] = [Wire.inet_checksum(raw)].pack('n')
    e = assert_raise(Wire::Error) { Wire.decode(raw) }
    assert_match(/claims 4294967295 LSAs/, e.message)
  end

  # 2. A packet flood neither starves timers nor kills the loop thread.
  def test_flood_does_not_starve_timers_or_kill_the_loop
    loop = EventLoop.new(on_error: ->(_) {}).start
    ticks = Thread::Queue.new
    loop.call { loop.every(0.02) { ticks << :tick } }
    stop = false
    feeder = Thread.new { until stop; loop.offer { 50.times { 1 + 1 } }; Thread.pass; end }
    Timeout.timeout(5) { 5.times { ticks.pop } }
    assert loop.running?
  ensure
    stop = true
    feeder&.join
    loop&.stop
  end

  def test_offer_drops_past_the_queue_limit
    loop = EventLoop.new(clock: Clock::Fake.new)
    n = 0
    (EventLoop::MAX_QUEUE + 5).times { loop.offer { n += 1 } }
    assert_equal 5, loop.dropped
    loop.drain
    assert_equal EventLoop::MAX_QUEUE, n
  end

  # 3. After a flush, the next origination still waits MinLSInterval.
  def test_reorigination_after_a_flush_waits_min_ls_interval
    seg = @lab.segment
    r = @lab.router('1.1.1.1', [seg, '10.0.0.1/24'])
    @lab.start
    @lab.advance(1)
    area = r.area(0)
    key = [2, Addr.to_i('10.0.0.1'), r.router_id]
    spec = { type: 2, ls_id: key[1], body: [0xffffff00, r.router_id, 9].pack('N*') }
    r.originate(area, spec)
    @lab.advance(6)
    r.flush_own(area, key)
    assert area.lsdb[key].max_age?
    r.originate(area, spec)
    assert area.lsdb[key].max_age?, 'held back right after the flush'
    @lab.advance(5.1)
    # The deferred origination asks the area, which no longer wants a
    # network-LSA here (no full neighbors), so it stays flushed. What
    # matters is that nothing went out inside MinLSInterval.
    assert area.lsdb[key].nil? || area.lsdb[key].max_age?
  end

  # 4. Malformed LSA bodies raise Lsa::Error, nothing else.
  def test_malformed_lsa_bodies
    short = Lsa.build(type: 1, ls_id: 1, advr: 1, seq: 1, body: "\0\0")
    assert_raise(Lsa::Error) { short.router_body }
    lying = Lsa.build(type: 1, ls_id: 1, advr: 1, seq: 1, body: [0, 0, 3].pack('CCn') + "\0" * 12)
    assert_raise(Lsa::Error) { lying.router_links }
    tos = Lsa.build(type: 1, ls_id: 1, advr: 1, seq: 1, body: [0, 0, 1].pack('CCn') + [1, 2, 1, 4, 10].pack('NNCCn'))
    assert_raise(Lsa::Error) { tos.router_links }
    assert_raise(Lsa::Error) { Lsa.build(type: 2, ls_id: 1, advr: 1, seq: 1, body: '').network_body }
    assert_raise(Lsa::Error) { Lsa.build(type: 2, ls_id: 1, advr: 1, seq: 1, body: "\0" * 9).network_body }
  end

  # 5. InterfaceDown runs no election and sends nothing.
  def test_interface_down_is_quiet
    lan = @lab.segment
    rs = (1..4).map { |n| @lab.router("#{n}.#{n}.#{n}.#{n}", [lan, "10.0.0.#{n}/24"]) }
    @lab.start
    @lab.converge(rs, adjacent: [[rs[3], rs[0]], [rs[2], rs[0]]])
    sent = capture(lan)
    rs[0].interfaces['eth0'].down
    @lab.loop.drain
    assert_equal [], sent.select { |_, from, *| from == '10.0.0.1' }
    assert @lab.log.none? { |l| l.start_with?('1.1.1.1') && l =~ /-> (dr|backup) / && l.include?('NeighborChange') }
  end

  # 6. A stale copy is answered at most once per MinLSArrival.
  def test_sending_our_copy_back_is_rate_limited
    seg = @lab.segment
    a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', { type: :p2p }])
    b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', { type: :p2p }])
    @lab.start
    @lab.converge([a, b])
    mine = @lab.lsa(a, 1, '1.1.1.1')
    stale = Lsa.router(advr: '1.1.1.1', seq: mine.seq - 1, links: [])
    sent = capture(seg)
    nbr = @lab.neighbor(a, '2.2.2.2')
    5.times { a.receive_update(nbr, Wire::LinkStateUpdate.new(lsas: [stale])) }
    assert_equal 1, sent.count { |_, from, _, type, _| from == '10.0.12.1' && type == Wire::LSU }
    @lab.advance(1.1)
    a.receive_update(nbr, Wire::LinkStateUpdate.new(lsas: [stale]))
    assert_equal 2, sent.count { |_, from, _, type, _| from == '10.0.12.1' && type == Wire::LSU }
  end

  # 7. Each LSA is retransmitted RxmtInterval after it went out, not with
  # whatever else happens to be on the list.
  def test_retransmit_waits_per_entry
    seg = @lab.segment
    a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', { type: :p2p }])
    b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', { type: :p2p }])
    @lab.start
    @lab.converge([a, b])
    nbr = @lab.neighbor(a, '2.2.2.2')
    l1 = Lsa.build(type: 5, ls_id: 1, advr: '7.7.7.7', seq: 1, body: "\0" * 16)
    l2 = Lsa.build(type: 5, ls_id: 2, advr: '7.7.7.7', seq: 1, body: "\0" * 16)
    log = []
    seg.drop_if do |bytes, from, _| # log A's updates, lose all of B's acks
      if from == '10.0.12.1' && bytes.getbyte(1) == Wire::LSU
        log << [@lab.loop.now.round(1), Wire.decode(bytes).body.lsas.map { |l| l.ls_id }]
      end
      from == '10.0.12.2'
    end
    t0 = @lab.loop.now
    a.flood(l1, a.area(0))
    @lab.advance(3)
    a.flood(l2, a.area(0))
    @lab.advance(3)
    assert_equal [[t0.round(1), [1]], [(t0 + 3).round(1), [2]], [(t0 + 5).round(1), [1]]],
                 log.map { |t, ids| [t, ids] }.first(3)
    assert nbr.retransmitting?(l1.key) && nbr.retransmitting?(l2.key)
  end

  # 8. A router-LSA with our advertising router but someone else's LS ID
  # is flushed, not answered by bumping our real router-LSA.
  def test_bogus_router_lsa_with_our_id_is_flushed
    seg = @lab.segment
    a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', { type: :p2p }])
    b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', { type: :p2p }])
    @lab.start
    @lab.converge([a, b])
    real = @lab.lsa(a, 1, '1.1.1.1')
    bogus = Lsa.router(advr: '1.1.1.1', seq: 50, links: []).bytes.dup
    bogus[4, 4] = [Addr.to_i('9.9.9.9')].pack('N') # LS ID
    bogus[16, 2] = "\0\0"
    bogus[16, 2] = Fletcher.compute(bogus)
    a.receive_update(@lab.neighbor(a, '2.2.2.2'), Wire::LinkStateUpdate.new(lsas: [Lsa.new(bogus)]))
    assert a.area(0).lsdb[[1, Addr.to_i('9.9.9.9'), a.router_id]].max_age?, 'flushed'
    assert_equal real.seq, @lab.lsa(a, 1, '1.1.1.1').seq, 'our real router-LSA did not move'
  end

  # 9. A stopped router originates nothing more.
  def test_stop_leaves_nothing_running
    seg = @lab.segment
    a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', { type: :p2p }])
    b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', { type: :p2p }])
    @lab.start
    @lab.converge([a, b])
    a.stop
    before = a.stats[:lsa_originated]
    @lab.advance(OSPFv2::LSRefreshTime + 10)
    assert_equal before, a.stats[:lsa_originated]
  end

  # 10. On point-to-point networks every packet goes to AllSPFRouters.
  def test_point_to_point_sends_everything_to_all_spf_routers
    seg = @lab.segment
    sent = capture(seg)
    a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', { type: :p2p }])
    b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', { type: :p2p }])
    300.times { |i| a.as_lsdb.install(Lsa.build(type: 5, ls_id: i, advr: '7.7.7.7', seq: 1, body: "\0" * 16)) }
    @lab.start
    @lab.converge([a, b])
    types = sent.map { |_, _, _, type, _| type }.uniq.sort
    assert_equal [1, 2, 3, 4, 5], types, 'every packet type was exercised'
    assert_equal [AllSPFRouters], sent.map { |_, _, dest, *| dest }.uniq
  end
end
