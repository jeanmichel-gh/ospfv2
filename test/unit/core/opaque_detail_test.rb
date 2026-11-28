# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'

# show.database's detail for opaque LSAs, in the shape
# docs/design/sr-ospf.md's "Answers for routescope", answer 2, gives.
class TestCoreOpaqueDetail < Test::Unit::TestCase
  include OSPFv2::Core
  D = OpaqueDetail

  # FRR 10.5.1's RI (router_information_test.rb): TE support set, bit 3.
  FRR_RI = '00010004100000000008000100ffffff0009000c001f40000001000300465000000e000c0003e800000100030036b000'

  def test_router_information
    assert_equal({ tlvs: [
                   { type: 1, name: 'informational-capabilities', bits: ['traffic-engineering'] },
                   { type: 8, name: 'sr-algorithm', algorithms: [0] },
                   { type: 9, name: 'sid-label-range', size: 8000, label: 18_000 },
                   { type: 14, name: 'srlb', size: 1000, label: 14_000 }
                 ] }, D.of(4, [FRR_RI].pack('H*')))
  end

  # As answer 2's example: 10.255.0.1/32, N, index 1.
  def test_extended_prefix
    body = ExtendedPrefix::Body.new(tlvs: [ExtendedPrefix::Prefix.new(
      prefix: '10.255.0.1/32', flags: ExtendedPrefix::N_FLAG, subs: [ExtendedPrefix::PrefixSid.new(sid: 1)]
    )]).encode
    assert_equal({ tlvs: [{ type: 1, name: 'extended-prefix', route_type: 1, prefix: '10.255.0.1/32', af: 0, flags: ['N'],
                            sub_tlvs: [{ type: 2, name: 'prefix-sid', flags: [], mt_id: 0, algorithm: 0, index: 1 }] }] },
                 D.of(7, body))
  end

  # As answer 2's example: p2p, V and L, label 15000; and a LAN Adj-SID.
  def test_extended_link
    link = ExtendedLink::Link.new(link_type: 1, link_id: '10.255.0.2', link_data: '10.0.12.1', subs: [
                                    ExtendedLink::AdjSid.new(flags: 0x60, sid: 15_000),
                                    ExtendedLink::LanAdjSid.new(flags: 0xe0, sid: 15_001, neighbor: '10.255.0.4')
                                  ])
    assert_equal({ tlvs: [{ type: 1, name: 'extended-link', link_type: 'p2p', link_id: '10.255.0.2', link_data: '10.0.12.1',
                            sub_tlvs: [
                              { type: 2, name: 'adj-sid', flags: %w[V L], mt_id: 0, weight: 0, label: 15_000 },
                              { type: 3, name: 'lan-adj-sid', flags: %w[B V L], mt_id: 0, weight: 0, neighbor: '10.255.0.4',
                                label: 15_001 }
                            ] }] }, D.of(8, ExtendedLink::Body.new(tlvs: [link]).encode))
  end

  def test_an_invalid_pair_gives_value_and_finding
    sid = ExtendedPrefix::PrefixSid.new(flags: ExtendedPrefix::PrefixSid::V, sid: 9)
    assert_equal({ value: 9, finding: 'prefix_sid_vl_invalid' }, D.sub(sid).slice(:value, :finding, :index, :label))
    adj = ExtendedLink::AdjSid.new(flags: ExtendedLink::AdjSid::V, sid: 9, octets: 3)
    assert_equal({ value: 9, finding: 'adj_sid_vl_invalid' }, D.sub(adj).slice(:value, :finding, :index, :label))
  end

  def test_unknown_ones_give_hex
    fad = [16, 4, 128, 0, 0, 0].pack('nnC4')
    assert_equal({ type: 16, hex: '80000000' }, D.of(4, fad)[:tlvs].first)
    assert_equal({ hex: 'abcd' }, D.of(1, "\xab\xcd".b), 'TE is not decoded')
  end

  def test_two_sid_labels_in_a_range
    r = RouterInformation::SidLabelRange.new(size: 100, subs: [{ type: 1, sid: 100 }, { type: 1, sid: 200 }])
    assert_equal({ type: 9, name: 'sid-label-range', size: 100, label: 100, finding: 'range_two_sid_labels' }, D.tlv(r))
  end
end
