# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/fault'
require 'support/core_lab'

# The catalog against the rules (docs/design/sr-ospf.md, step 0): each
# entry makes the finding it names, and no other, under :rfc.
class TestFault < Test::Unit::TestCase
  include OSPFv2
  V = OSPFv2::Validation
  F = OSPFv2::Fault

  def test_every_opaque_and_sr_rule_has_an_entry_and_every_entry_a_rule
    rules = V::RULES.values.select { %i[opaque sr].include?(_1.group) }.map(&:name).sort
    assert_equal rules, F.catalog.map { _1[:finding] }.sort
    assert_equal F.names.uniq, F.names
  end

  # Each SR entry through the body check, the stub entry through ospfd.
  def test_each_entry_makes_its_finding_and_no_other
    F.catalog.each do |e|
      next if e[:name] == :opaque_as_in_stub
      l = F.lsa(e[:name])
      opaque_type = l.ls_id >> 24
      assert_equal [e[:finding]], V.opaque(opaque_type, l.body, Core::Addr.to_s(l.advr)).map(&:name), e[:name].to_s
    end
  end

  # Two routers Full in stub area 1. A type 11 from the neighbor is
  # dropped, counted by its finding, and not acknowledged.
  def test_a_type_11_into_a_stub_area
    lab = CoreLab.new
    seg = lab.segment
    p2p = { type: :p2p, area: 1 }
    a = lab.router('1.1.1.1', [seg, '10.0.12.1/30', p2p])
    b = lab.router('2.2.2.2', [seg, '10.0.12.2/30', p2p])
    [a, b].each { |r| r.area_options = { 1 => { stub: {} } } }
    lab.start
    assert lab.run_until(60) { lab.full?(a, b) }
    lsa = F.lsa(:opaque_as_in_stub, router_id: '1.1.1.1')
    b.receive_update(lab.neighbor(b, '1.1.1.1'), Core::Wire::LinkStateUpdate.new(lsas: [lsa]))
    stats = b.interfaces['eth0'].stats
    assert_equal [1, 1], stats.values_at(:drop_lsa, :finding_opaque_as_in_stub)
    ev = b.events.reverse.find { _1.kind == :drop }
    assert_equal 'opaque_as_in_stub', ev.data[:finding]
    assert_match(/type 11 opaque LSA in a stub area or NSSA from/, ev.message)
  end

  def test_each_entry_is_an_lsa_with_a_good_checksum
    F.names.each do |n|
      octets = F.wire(n)
      l = Core::Lsa.parse(octets)
      assert l.checksum_ok?, n.to_s
      assert_equal octets, l.bytes, n.to_s
      assert_equal '10.255.0.9', Core::Addr.to_s(l.advr), n.to_s
    end
    assert_equal 11, F.lsa(:opaque_as_in_stub).type
    assert_equal '7.0.0.1', Core::Addr.to_s(F.lsa(:tlv_overrun).ls_id)
  end

  def test_an_entry_says_what_the_rfc_expects
    e = F.entry(:prefix_sid_vl_invalid)
    assert_equal [:sr, :ignore_sid], e.values_at(:group, :expect)
    assert_match(/\ARFC 8665 section 5: /, e[:rfc])
    assert_equal :drop_lsa, F.entry(:opaque_as_in_stub)[:expect]
  end

  def test_an_unknown_fault
    e = assert_raise(ArgumentError) { F.entry(:bogus) }
    assert_match(/unknown fault :bogus; the faults are opaque_as_in_stub, /, e.message)
  end
end
