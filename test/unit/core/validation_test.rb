# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core/validation'
require 'ospfv2/fault'

# The rules, the policies and the walk of opaque LSA bodies
# (docs/design/sr-ospf.md, step 0).
class TestValidation < Test::Unit::TestCase
  V = OSPFv2::Validation
  F = OSPFv2::Fault

  def test_every_rule_has_its_three_actions_and_a_clause
    V::RULES.each_value do |r|
      assert_equal V::POLICIES, r.actions.keys, r.name
      assert_includes V::GROUPS, r.group, r.name
      assert_match(/\ARFC \d+ section [\d.]+/, r.clause, r.name.to_s)
    end
  end

  def test_the_policy
    assert_equal :rfc, V.policy(nil)
    assert_equal :strict, V.policy('strict')
    e = assert_raise(ArgumentError) { V.policy(:loose) }
    assert_equal 'receive_policy is rfc, strict, lenient, not loose', e.message
  end

  def test_a_finding
    f = V.finding(:sid_label_range_zero, '10.255.0.9', 'SID/Label Range of size 0')
    assert_equal :sr, f.group
    assert_equal :ignore_range, V.action(f, :rfc)
    assert_equal :ignore_router, V.action(f, :strict)
    assert_match(/\A10.255.0.9: SID\/Label Range of size 0 \(RFC 8665 section 3.2/, f.to_s)
    assert_equal %w[name group clause subject detail], f.to_hash.keys.map(&:to_s)
    assert_raise(ArgumentError) { V.finding(:bogus, 's', 'd') }
  end

  # A correct RI and extended prefix body, as the catalog builds them.
  def test_correct_bodies_make_none
    c = F.context
    assert_equal [], V.opaque(4, F.router_information(c), 'x')
    assert_equal [], V.opaque(7, F.extended_prefix(c), 'x')
    assert_equal [], V.opaque(7, F.extended_prefix(c, flags: F::V_FLAG | F::L_FLAG), 'x'), 'a label: V and L set'
    assert_equal [], V.opaque(1, "\xff".b * 3, 'x'), 'TE is not read here'
  end

  def test_the_walk_stops_at_an_overrun
    assert_equal [:tlv_overrun], V.opaque(4, [8, 9].pack('nn') + "\0\0\0\0", 'x').map(&:name)
    assert_equal [:tlv_overrun], V.opaque(4, "\0\x08".b, 'x').map(&:name), 'less than a TLV header'
    assert_equal [:tlv_overrun], V.opaque(7, F.tlv(1, "\x01\x20".b), 'x').map(&:name), 'short of its 8 fixed octets'
    assert_equal [:tlv_overrun], V.opaque(4, F.tlv(9, "\0\0".b), 'x').map(&:name), 'a range short of its 4 octets'
  end

  def test_padding_is_skipped
    # A 1-octet SR-Algorithm TLV is padded to 8 octets (RFC 7770 section 2.3).
    body = F.tlv(8, "\0".b) + F.range(9, [16_000, 8_000])
    assert_equal 16, F.tlv(8, "\0".b).bytesize + 8
    assert_equal [], V.opaque(4, body, 'x')
  end
end
