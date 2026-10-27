# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'support/core_lab'

# Not-so-stubby areas (RFC 3101).
#
#   R1 (area 0, ASBR) -- R2 (ABR) -- R3 (area 1 NSSA, ASBR, loopback 3.3.3.3)
#           \-------- R4 (ABR) ------/            (R4 only in the two-ABR test)
class TestCoreNssa < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  A = ->(s) { Addr.to_i(s) }
  P2P = { type: :p2p }.freeze

  def build(nssa: {}, second_abr: false)
    @lab = CoreLab.new
    s12, s23, s14, s43 = Array.new(4) { @lab.segment }
    a1 = P2P.merge(area: 1)
    @r1 = @lab.router('1.1.1.1', [s12, '10.0.12.1/30', P2P], *(second_abr ? [[s14, '10.0.14.1/30', P2P]] : []))
    @r2 = @lab.router('2.2.2.2', [s12, '10.0.12.2/30', P2P], [s23, '10.0.23.1/30', a1])
    @r3 = @lab.router('3.3.3.3', [s23, '10.0.23.2/30', a1], [:passive, '3.3.3.3/32', { area: 1 }],
                      *(second_abr ? [[s43, '10.0.34.2/30', a1]] : []))
    rs = [@r2, @r3]
    if second_abr
      @r4 = @lab.router('4.4.4.4', [s14, '10.0.14.2/30', P2P], [s43, '10.0.34.1/30', a1])
      rs << @r4
    end
    rs.each { |r| r.area_options = { 1 => { nssa: { default_lsa: nil, no_summaries: false }.merge(nssa) } } }
    @lab.start
    @r1.externals = [{ prefix: A['198.51.100.0'], prefix_len: 24, metric: 30, type: 2, tag: 0 }]
    @r3.externals = [{ prefix: A['192.0.2.0'], prefix_len: 24, metric: 20, type: 2, tag: 5 }]
    assert @lab.run_until(120) { route(@r1, '192.0.2.0/24') && (route(@r3, '10.0.12.0/30') || route(@r3, '0.0.0.0/0')) }
    @lab.advance(10)
  end

  def route(r, prefix)
    p, len = prefix.split('/')
    r.routes[[A[p], len.to_i]]
  end

  def lsas(r, type, area = 1)
    db = type == 5 ? r.as_lsdb : r.areas[area].lsdb
    db.select { |l| l.type == type && !l.max_age? }
  end

  def test_routes_from_an_nssa_are_translated_into_the_backbone
    build
    t7 = lsas(@r3, 7).find { |l| l.advr == @r3.router_id }
    mask, m, fwd, tag = t7.body.unpack('NNNN')
    assert_equal [A['255.255.255.0'], 0x8000_0014, A['3.3.3.3'], 5], [mask, m, fwd, tag]
    assert_equal 0x08, t7.options & 0x08, 'P bit: please translate'
    assert_equal 2, @r3.areas[1].lsdb[[1, @r3.router_id, @r3.router_id]].router_body[0] & 2, 'E bit in the NSSA'
    n2 = route(@r2, '192.0.2.0/24')
    assert_equal [:ext2, 7], [n2.path_type, n2.lsa_type]
    t5 = lsas(@r1, 5).find { |l| l.ls_id == A['192.0.2.0'] }
    assert_equal @r2.router_id, t5.advr, 'the ABR translates'
    assert_equal [A['255.255.255.0'], 0x8000_0014, A['3.3.3.3'], 5], t5.body.unpack('NNNN'), 'same metric, FA, tag'
    r = route(@r1, '192.0.2.0/24')
    assert_equal [:ext2, 30, 20], [r.path_type, r.cost, r.type2_cost], 'distance to the forwarding address: 10 + 10 + 10'
  end

  def test_an_nssa_takes_no_type_5_but_keeps_summaries
    build
    assert_empty @r3.as_lsdb.to_a
    assert_nil route(@r3, '198.51.100.0/24')
    assert_empty lsas(@r3, 4), 'no ASBR summaries'
    assert(lsas(@r3, 3).any? { |l| l.ls_id == A['10.0.12.0'] })
    assert_equal 0, @r3.areas[1].lsdb[[1, @r3.router_id, @r3.router_id]].options & 0x0a, 'no E bit in its LSAs'
    assert_equal 0x08, @r3.interfaces['eth0'].options, 'N bit in hellos'
  end

  def test_the_default_lsa
    build(nssa: { default_lsa: { metric: 7, type: 1 } })
    d = route(@r3, '0.0.0.0/0')
    assert_equal [:ext1, 17, 7], [d.path_type, d.cost, d.lsa_type]
    t7 = lsas(@r3, 7).find { |l| l.advr == @r2.router_id && l.ls_id.zero? }
    assert_equal 0, t7.options & 0x08, 'never translated'
    assert_nil(lsas(@r1, 5).find { |l| l.ls_id.zero? })
  end

  def test_no_summaries_leaves_a_type_3_default
    build(nssa: { no_summaries: true, default_lsa: { metric: 4, type: 2 } })
    assert_equal [0], lsas(@r3, 3).map(&:ls_id)
    assert_equal [:inter, 14], route(@r3, '0.0.0.0/0').then { |d| [d.path_type, d.cost] }
    assert_empty(lsas(@r3, 7).select { |l| l.advr == @r2.router_id }, 'no type 7 default then')
  end

  def test_the_highest_router_id_translates
    build(second_abr: true)
    @lab.advance(45) # a translator that lost keeps going 40 s (RFC 3101 3.1)
    adv = lsas(@r1, 5).select { |l| l.ls_id == A['192.0.2.0'] }.map { |l| Addr.to_s(l.advr) }
    assert_equal ['4.4.4.4'], adv
  end

  def test_a_router_that_disagrees_about_nssa_is_kept_out
    build
    lab_seg = @lab.segment
    r5 = @lab.router('5.5.5.5', [lab_seg, '10.0.35.1/30', P2P.merge(area: 1)])
    @r3.add_interface(name: 'eth9', address: '10.0.35.2/30', area: 1,
                      transport: Transport::Loopback.new(lab_seg, '10.0.35.2'), type: :p2p)
    r5.start
    @lab.advance(30)
    assert_empty r5.neighbors.select(&:full?)
    assert_match(/(E|N) bit mismatch/, @lab.log.join("\n"))
  end

  # ---- review fixes ----

  def test_border_routers_ignore_each_others_default
    build(nssa: { default_lsa: { metric: 7, type: 2 } }, second_abr: true)
    assert_nil route(@r2, '0.0.0.0/0'), 'R2 would send default traffic to R4 and back'
    assert_nil route(@r4, '0.0.0.0/0')
    assert route(@r3, '0.0.0.0/0'), 'the routers inside take it'
  end

  def test_no_type_4_for_an_nssa_asbr
    build
    assert_empty(lsas(@r1, 4, 0).select { |l| l.ls_id == A['3.3.3.3'] })
    assert_nil @r1.route_table.routers.values.find { |r| r.prefix == A['3.3.3.3'] }
  end

  def test_own_summaries_and_externals_trigger_no_spf
    build
    kinds = @r2.spf_log.flat_map { |run| run.reasons.select { |x| x.detail.to_s.end_with?('from 2.2.2.2') } }
    assert_empty kinds
  end

  def test_an_area_turning_nssa_does_not_break_our_externals
    build
    @r1.externals = [{ prefix: A['198.51.100.0'], prefix_len: 24, metric: 30, type: 2, tag: 0 }]
    lab = @lab
    @r2.externals = [{ prefix: A['203.0.113.0'], prefix_len: 24, metric: 5, type: 2, tag: 0 }]
    lab.advance(10)
    # Area 0 on R1 turns into an NSSA under the type 5 it originated.
    @r1.area_options = { 0 => { nssa: { default_lsa: nil, no_summaries: false } } }
    lab.advance(OSPFv2::LSRefreshTime + 200)
    @r1.stop(flush: true)
    refute @r1.running?
  end
end
