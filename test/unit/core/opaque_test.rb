# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'support/core_lab'

# Opaque LSAs in the core (RFC 5250; docs/design/sr-ospf.md, step 1):
# the O bit in DDs, types 9 to 11 held, flooded in their scope, and only
# to neighbors that set O.
class TestCoreOpaque < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  A = ->(s) { Addr.to_i(s) }
  P2P = { type: :p2p }.freeze
  RI = A['4.0.0.0'] # opaque type 4, ID 0

  def setup
    @lab = CoreLab.new
  end

  # a -- b -- c, each link its own segment.
  def line(opaque: %w[a b c], areas: [0, 0])
    s1 = @lab.segment
    s2 = @lab.segment
    @a = @lab.router('1.1.1.1', [s1, '10.0.12.1/30', P2P.merge(area: areas[0])])
    @b = @lab.router('2.2.2.2', [s1, '10.0.12.2/30', P2P.merge(area: areas[0])], [s2, '10.0.23.1/30', P2P.merge(area: areas[1])])
    @c = @lab.router('3.3.3.3', [s2, '10.0.23.2/30', P2P.merge(area: areas[1])])
    { 'a' => @a, 'b' => @b, 'c' => @c }.each { |n, r| r.opaque = opaque.include?(n) }
  end

  def up
    @lab.start
    assert @lab.run_until(120) { @lab.full?(@a, @b) && @lab.full?(@b, @c) }
  end

  def ri(body = "\x00\x01\x00\x04\x00\x00\x00\x00".b, area: '0.0.0.0', type: 10)
    [{ type: type, area: area, opaque_type: 4, opaque_id: 0, body: body }.compact]
  end

  def has?(r, type, ls_id = RI, advr = '1.1.1.1', db: nil)
    db ||= type == 11 ? r.as_lsdb : r.areas.values.first.lsdb
    !db[[type, ls_id, A[advr]]].nil?
  end

  def test_the_o_bit_is_in_dds_only
    line
    up
    nbr = @lab.neighbor(@b, '1.1.1.1')
    assert nbr.opaque?, 'a set O in its DDs'
    assert_equal true, nbr.summary[:opaque]
    assert_equal 0x42, @b.interfaces['eth0'].dd_options
    assert_equal 0x02, @b.interfaces['eth0'].options, 'not in Hellos (RFC 5250 section 3.1)'
  end

  def test_with_opaque_off_the_dds_are_as_before
    line(opaque: [])
    up
    nbr = @lab.neighbor(@b, '1.1.1.1')
    refute nbr.opaque?
    assert_equal 0x02, nbr.options
    assert_equal false, nbr.summary[:opaque]
  end

  def test_a_type_10_floods_through_the_area
    line
    up
    @a.opaque_lsas = ri
    assert @lab.run_until(30) { has?(@c, 10) }
    l = @c.areas[0].lsdb[[10, RI, A['1.1.1.1']]]
    assert_equal 0x42, l.options, 'E and O'
    assert @lab.run_until(30) { @lab.quiet?(@a, @b, @c) }
  end

  # c starts after a has its type 10: it learns it by the database exchange.
  def test_a_type_10_in_the_database_exchange
    line
    @a.start
    @b.start
    assert @lab.run_until(60) { @lab.full?(@a, @b) }
    @a.opaque_lsas = ri
    assert @lab.run_until(30) { has?(@b, 10) }
    @c.start
    assert @lab.run_until(60) { @lab.full?(@b, @c) }
    assert has?(@c, 10)
  end

  # RFC 5250 section 3.1: not on the retransmission list of a neighbor
  # without O, so nothing goes out to it.
  def test_a_neighbor_without_o_gets_none
    line(opaque: %w[a b])
    up
    @a.opaque_lsas = ri
    assert @lab.run_until(30) { has?(@b, 10) }
    @lab.advance(10)
    refute @lab.neighbor(@b, '3.3.3.3').opaque?
    assert_equal 0, @c.interfaces['eth0'].stats[:drop_lsa], 'c was sent nothing it would drop'
    refute has?(@c, 10)
    assert_empty @lab.neighbor(@b, '3.3.3.3').retransmit
  end

  def test_a_type_11_floods_but_not_into_a_stub_area
    line(areas: [0, 1])
    [@b, @c].each { |r| r.area_options = { 1 => { stub: {} } } }
    up
    @a.opaque_lsas = ri(area: nil, type: 11)
    assert @lab.run_until(30) { has?(@b, 11) }
    @lab.advance(10)
    refute has?(@c, 11), 'RFC 5250 section 3.1: not flooded into a stub area'
  end

  # A type 9 from a is kept on b's interface to a and goes no further.
  def test_a_type_9_stays_on_its_interface
    line
    up
    lsa = Lsa.build(type: 9, ls_id: RI, advr: '1.1.1.1', seq: Lsa::INITIAL_SEQ, body: "\0\1\0\4\0\0\0\0".b, options: 0x42)
    @b.receive_update(@lab.neighbor(@b, '1.1.1.1'), Wire::LinkStateUpdate.new(lsas: [lsa]))
    @lab.advance(10)
    assert_not_nil @b.interfaces['eth0'].link_lsdb[lsa.key]
    assert_nil @b.interfaces['eth1'].link_lsdb[lsa.key]
    assert_empty @c.link_database
    assert_equal [['eth0', lsa.key]], @b.link_database.map { |i, l| [i.name, l.key] }
  end

  def test_a_dd_that_offers_a_type_11_in_a_stub_area
    line(areas: [1, 1])
    [@a, @b, @c].each { |r| r.area_options = { 1 => { stub: {} } } }
    up
    nbr = @lab.neighbor(@b, '1.1.1.1')
    h = Lsa.build(type: 11, ls_id: RI, advr: '1.1.1.1', seq: Lsa::INITIAL_SEQ, body: ''.b).header
    nbr.send(:accept_dd, Wire::DatabaseDescription.new(mtu: 1500, options: 0x40, flags: 0, seq: 1, headers: [h]))
    assert_equal 1, @b.interfaces['eth0'].stats[:finding_dd_opaque_as_in_stub]
  end

  def test_with_opaque_off_a_type_10_is_an_unknown_type
    line(opaque: [])
    up
    lsa = Lsa.build(type: 10, ls_id: RI, advr: '1.1.1.1', seq: Lsa::INITIAL_SEQ, body: ''.b)
    @b.receive_update(@lab.neighbor(@b, '1.1.1.1'), Wire::LinkStateUpdate.new(lsas: [lsa]))
    assert_equal 1, @b.interfaces['eth0'].stats[:finding_unsupported_lsa_type]
    assert_raise(ArgumentError) { @a.opaque_lsas = ri }
  end

  def test_one_withdrawn_is_flushed_everywhere
    line
    up
    @a.opaque_lsas = ri
    assert @lab.run_until(30) { has?(@c, 10) }
    @a.opaque_lsas = []
    assert @lab.run_until(60) { !has?(@c, 10) && !has?(@a, 10) }
  end

  def test_a_changed_body_is_a_new_instance
    line
    up
    @a.opaque_lsas = ri
    assert @lab.run_until(30) { has?(@c, 10) }
    seq = @c.areas[0].lsdb[[10, RI, A['1.1.1.1']]].seq
    @lab.advance(OSPFv2::MinLSInterval)
    @a.opaque_lsas = ri("\x00\x01\x00\x04\x10\x00\x00\x00".b)
    assert @lab.run_until(30) { @c.areas[0].lsdb[[10, RI, A['1.1.1.1']]].seq == seq + 1 }
  end

  # Off again: every adjacency forms anew without O, and what was held goes.
  def test_opaque_turned_off
    line
    up
    @a.opaque_lsas = ri
    assert @lab.run_until(30) { has?(@c, 10) }
    @b.opaque = false
    refute has?(@b, 10)
    assert @lab.run_until(120) { @lab.full?(@a, @b) && @lab.full?(@b, @c) }
    refute @lab.neighbor(@a, '2.2.2.2').opaque?
    refute has?(@b, 10)
  end

  def test_opaque_is_not_in_spf
    line
    up
    @lab.advance(30)
    runs = @c.spf.runs
    @a.opaque_lsas = ri
    assert @lab.run_until(30) { has?(@c, 10) }
    @lab.advance(10)
    assert_equal runs, @c.spf.runs
  end

  def test_bad_opaque_lsas
    line
    assert_raise(ArgumentError) { @a.opaque_lsas = [{ type: 9, opaque_type: 1, opaque_id: 0, body: '' }] }
    assert_raise(ArgumentError) { @a.opaque_lsas = [{ type: 10, area: '0.0.0.0', opaque_type: 256, opaque_id: 0, body: '' }] }
    assert_raise(ArgumentError) { @a.opaque_lsas = [{ type: 10, area: '0.0.0.0', opaque_type: 4, opaque_id: 1 << 24, body: '' }] }
  end
end
