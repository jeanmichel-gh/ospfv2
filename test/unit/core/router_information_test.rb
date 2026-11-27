# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'ospfv2/fault'
require 'support/core_lab'

# The Router Information LSA (RFC 7770; docs/design/sr-ospf.md, step 2):
# its codec, ospfd's own in each area, and reading other routers'.
class TestCoreRouterInformation < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core
  RI = Core::RouterInformation
  A = ->(s) { Addr.to_i(s) }

  # ---- the codec

  # Each TLV built four ways, and its octets, worked out from RFC 8665
  # sections 2.1, 3.1 to 3.3 and RFC 7770 section 2.4.
  CASES = [
    [RI::Capabilities, { bits: 0x1000_0000 }, '0001000410000000'],
    [RI::SrAlgorithm, { algorithms: [0] }, '0008000100000000'],
    [RI::SrAlgorithm, { algorithms: [0, 1] }, '0008000200010000'],
    [RI::SidLabelRange, { first: 16_000, size: 8_000 }, '0009000c001f4000000100030' + '03e8000'],
    [RI::Srlb, { first: 15_000, size: 1_000 }, '000e000c0003e8000001000300' + '3a9800'],
    [RI::SidLabel, { sid: 16_000 }, '0001000300' + '3e8000']
  ].freeze

  def test_each_tlv_four_ways
    CASES.each do |klass, fields, hex|
      a = klass.new(**fields)
      assert_equal hex, a.to_shex, klass.name
      b = klass.new(a.to_hash)
      c = klass.new([hex].pack('H*'))
      d = klass.new(a)
      assert_equal [a.encode] * 3, [b, c, d].map(&:encode), klass.name
      assert_equal a, c
    end
  end

  def test_a_range_keeps_its_sub_tlvs
    r = RI::SidLabelRange.new(size: 100, subs: [{ type: 1, sid: 100 }, { type: 1, sid: 200 }])
    assert_equal [100, 2], [r.first, r.sid_labels]
    assert_equal r, RI::SidLabelRange.new(r.encode)
  end

  # An unknown TLV, RFC 9350's Flexible Algorithm Definition (16) here,
  # is kept and sent back unchanged (RFC 7770 section 2.3).
  def test_an_unknown_tlv_is_kept
    fad = [16, 4, 128, 0, 0, 0].pack('nnC4')
    body = RI.build(algorithms: [0]).encode + fad
    b = RI::Body.new(body)
    assert_equal body, b.encode
    u = b.tlvs.last
    assert_instance_of Tlv::Unknown, u
    assert_equal({ type: 16, value: '80000000' }, u.to_hash)
    assert_equal body, RI::Body.new(b.to_hash).encode
    assert_equal body, RI::Body.new(b).encode
  end

  # RFC 8665 section 3.2's example: three ranges, kept in their order.
  def test_ranges_keep_their_order
    b = RI.build(algorithms: [0], srgb: [[100, 100], [1000, 100], [500, 100]])
    assert_equal [[100, 100], [1000, 100], [500, 100]], RI::Body.new(b.encode).ranges(RI::SidLabelRange).map { [_1.first, _1.size] }
  end

  def test_a_tlv_past_its_end
    assert_raise(Tlv::Error) { RI::Body.new([8, 9, 0].pack('nnC')) }
  end

  # ---- ours, in each area

  def pair
    @lab = CoreLab.new
    seg = @lab.segment
    @a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', { type: :p2p }])
    @b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', { type: :p2p }])
    [@a, @b].each { _1.opaque = true }
    @lab.start
    assert @lab.run_until(60) { @lab.full?(@a, @b) }
  end

  def ri_of(r, advr) = r.areas[0].lsdb[[10, Instance::RI_ID, A[advr]]]

  def test_one_per_area_while_opaque_is_on
    pair
    assert @lab.run_until(30) { ri_of(@b, '1.1.1.1') }
    l = ri_of(@b, '1.1.1.1')
    assert_equal [{ type: 1, bits: 0 }], RI::Body.new(l.body).to_hash[:tlvs], 'no capability bits, no SR yet'
    assert_equal({ opaque_type: 4, opaque_id: 0, tlvs: [{ type: 1, bits: 0 }] }, l.detail)
    # The flush must come MinLSArrival after the LSA, or b discards it
    # (RFC 2328 13 (5a)) and keeps the LSA until MaxAge.
    @lab.advance(OSPFv2::MinLSArrival)
    @a.opaque = false
    assert @lab.run_until(60) { ri_of(@b, '1.1.1.1').nil? }
  end

  def test_sr_capabilities_are_sent_and_read
    pair
    @a.sr_capabilities = { algorithms: [0], srgb: [[16_000, 8_000]], srlb: [[15_000, 1_000]] }
    assert @lab.run_until(30) { @b.router_information(0).dig('1.1.1.1', :algorithms) }
    assert_equal({ router_id: '1.1.1.1', capabilities: 0, algorithms: [0], srgb: [[16_000, 8_000]], srlb: [[15_000, 1_000]],
                   findings: [] }, @b.router_information(0)['1.1.1.1'])
    assert_nil @b.router_information(0).dig('2.2.2.2', :algorithms), 'b has no SR: not SR capable'
  end

  # An RI as the catalog builds it, from 9.9.9.9, a router behind a,
  # received by b. Not from a itself: a would put its own back.
  def receive(name, **ctx)
    lsa = Fault.lsa(name, router_id: '9.9.9.9', seq: Lsa::INITIAL_SEQ + 5, **ctx)
    @b.receive_update(@lab.neighbor(@b, '1.1.1.1'), Wire::LinkStateUpdate.new(lsas: [lsa]))
    @b.router_information(0)['9.9.9.9']
  end

  def test_two_sr_algorithm_tlvs_the_first_is_used
    pair
    r = receive(:sr_algorithm_twice)
    assert_equal [0], r[:algorithms]
    assert_equal ['sr_algorithm_twice'], r[:findings].map { _1[:name] }
  end

  def test_two_sr_algorithm_tlvs_under_strict
    @lab = CoreLab.new
    seg = @lab.segment
    @a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', { type: :p2p }])
    @b = Instance.new(router_id: '2.2.2.2', loop: @lab.loop, receive_policy: :strict)
    @b.add_interface(name: 'eth0', address: '10.0.12.2/30', type: :p2p, transport: Transport::Loopback.new(seg, '10.0.12.2'))
    [@a, @b].each { _1.opaque = true }
    @lab.start
    @b.start
    assert @lab.run_until(60) { @lab.full?(@a, @b) }
    assert_nil receive(:sr_algorithm_twice)[:algorithms], 'strict: the router is left out of SR'
  end

  def test_ranges_a_finding_ignores_are_left_out
    pair
    assert_equal [], receive(:sid_label_range_zero)[:srgb]
    assert_equal [[15_000, 1_000]], @b.router_information(0)['9.9.9.9'][:srlb]
    @lab.advance(OSPFv2::MinLSArrival)
    assert_equal [], receive(:range_two_sid_labels, seq: Lsa::INITIAL_SEQ + 6)[:srgb]
    @lab.advance(OSPFv2::MinLSArrival)
    assert_equal [], receive(:srlb_range_zero, seq: Lsa::INITIAL_SEQ + 7)[:srlb]
  end

  # RFC 7684 section 5 and RFC 8665 section 9: not stored, counted.
  def test_a_malformed_one_is_dropped
    pair
    stored = ri_of(@b, '1.1.1.1')
    lsa = Fault.lsa(:tlv_overrun, router_id: '1.1.1.1')
    @b.receive_update(@lab.neighbor(@b, '1.1.1.1'), Wire::LinkStateUpdate.new(lsas: [lsa]))
    assert_equal 1, @b.interfaces['eth0'].stats[:finding_tlv_overrun]
    assert_nil @b.areas[0].lsdb[lsa.key]
    assert_equal stored, ri_of(@b, '1.1.1.1')
  end

  def test_ours_is_not_set_by_hand
    pair
    e = assert_raise(ArgumentError) { @a.opaque_lsas = [{ type: 10, area: '0.0.0.0', opaque_type: 4, opaque_id: 0, body: '' }] }
    assert_match(/ospfd's own/, e.message)
  end
end
