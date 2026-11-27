# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'ospfv2/fault'
require 'support/core_lab'

# The extended prefix and extended link LSAs (RFC 7684; docs/design/
# sr-ospf.md, step 3): their codec and reading other routers'.
class TestCoreExtended < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core
  XP = Core::ExtendedPrefix
  XL = Core::ExtendedLink

  # Each built four ways, against octets worked out from RFC 7684
  # sections 2.1 and 3.1 and RFC 8665 sections 5, 6.1 and 6.2.
  CASES = [
    [XP::PrefixSid, { flags: 0, algorithm: 0, sid: 3 }, '0002000800000000' + '00000003'],
    [XP::PrefixSid, { flags: 0x0c, algorithm: 0, sid: 16_003 }, '000200070c000000' + '003e8300'],
    [XP::Prefix, { route_type: 1, prefix: '10.255.0.3/32', flags: XP::N_FLAG, subs: [{ type: 2, flags: 0, sid: 3 }] },
     '00010014012000400aff0003' + '000200080000000000000003'],
    [XL::AdjSid, { flags: 0x60, weight: 0, sid: 15_001 }, '0002000760000000' + '003a9900'],
    [XL::LanAdjSid, { flags: 0x60, weight: 0, neighbor: '10.255.0.2', sid: 15_000 },
     '0003000b600000000aff0002' + '003a9800'],
    [XL::Link, { link_type: 1, link_id: '10.255.0.2', link_data: '10.0.12.1', subs: [{ type: 2, flags: 0x60, sid: 15_001 }] },
     '000100180100000' + '00aff00020a000c01' + '0002000760000000003a9900']
  ].freeze

  def test_each_tlv_four_ways
    CASES.each do |klass, fields, hex|
      a = klass.new(**fields)
      assert_equal hex, a.to_shex, klass.name
      assert_equal [a.encode] * 3, [klass.new(a.to_hash), klass.new([hex].pack('H*')), klass.new(a)].map(&:encode), klass.name
    end
  end

  def test_what_they_say
    p = XP::Prefix.new([CASES[2][2]].pack('H*'))
    assert_equal ['10.255.0.3/32', 3, false], [p.prefix_s, p.sids.first.sid, p.sids.first.label?]
    l = XL::Link.new([CASES[5][2]].pack('H*'))
    assert_equal [[1, Addr.to_i('10.255.0.2'), Addr.to_i('10.0.12.1')], [15_001], []],
                 [l.key, l.adj_sids.map(&:sid), l.lan_adj_sids]
    assert XL::AdjSid.new(flags: 0xe0, sid: 1).backup?
  end

  # RFC 9350's Flexible Algorithm Prefix Metric sub-TLV (type 3) is not
  # read here: it is kept and sent back.
  def test_an_unknown_sub_tlv_is_kept
    fapm = [3, 8, 128, 0, 0, 0, 10].pack('nnC4N')
    octets = XP::Body.new(tlvs: [XP::Prefix.new(prefix: '10.255.0.3/32', subs: [])]).encode
    raw = [1, 8 + fapm.bytesize].pack('nn') + octets.byteslice(4, 8) + fapm
    b = XP::Body.new(raw)
    assert_equal raw, b.encode
    assert_instance_of Tlv::Unknown, b.prefixes.first.subs.first
    assert_equal raw, XP::Body.new(b.to_hash).encode
  end

  # ---- reading

  def pair(policy: :rfc)
    @lab = CoreLab.new
    seg = @lab.segment
    @a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', { type: :p2p }])
    @b = Instance.new(router_id: '2.2.2.2', loop: @lab.loop, receive_policy: policy)
    @b.add_interface(name: 'eth0', address: '10.0.12.2/30', type: :p2p, transport: Transport::Loopback.new(seg, '10.0.12.2'))
    [@a, @b].each { _1.opaque = true }
    @lab.start
    @b.start
    assert @lab.run_until(60) { @lab.full?(@a, @b) }
  end

  # LSAs from 9.9.9.9, a router behind a, received by b.
  def receive(*lsas)
    @b.receive_update(@lab.neighbor(@b, '1.1.1.1'), Wire::LinkStateUpdate.new(lsas: lsas))
  end

  def prefix_lsa(oid, index, flags: 0)
    body = XP::Body.new(tlvs: [XP::Prefix.new(prefix: '9.9.9.9/32', flags: XP::N_FLAG,
                                              subs: [XP::PrefixSid.new(flags: flags, sid: index)])]).encode
    Lsa.build(type: 10, ls_id: (7 << 24) | oid, advr: '9.9.9.9', seq: Lsa::INITIAL_SEQ, body: body, options: 0x42)
  end

  def test_the_lowest_opaque_id_wins
    pair
    receive(prefix_lsa(5, 50), prefix_lsa(2, 20))
    r = @b.extended_prefixes(0)['9.9.9.9']
    assert_equal [2, [20]], r[:prefixes]['9.9.9.9/32'].values_at(:opaque_id).push(r[:prefixes]['9.9.9.9/32'][:sids].map { _1[:sid] })
    assert_equal [], r[:findings]
  end

  def test_a_sid_with_v_and_l_unequal_is_left_out
    pair
    receive(prefix_lsa(1, 9, flags: XP::PrefixSid::V))
    r = @b.extended_prefixes(0)['9.9.9.9']
    assert_equal [], r[:prefixes]['9.9.9.9/32'][:sids]
    assert_equal ['prefix_sid_vl_invalid'], r[:findings].map { _1[:name] }
  end

  def test_one_prefix_twice_in_one_lsa
    pair
    receive(Fault.lsa(:prefix_tlv_twice, router_id: '9.9.9.9'))
    r = @b.extended_prefixes(0)['9.9.9.9']
    assert_equal [9], r[:prefixes]['9.9.9.9/32'][:sids].map { _1[:sid] }, 'the first is used'
    assert_equal ['prefix_tlv_twice'], r[:findings].map { _1[:name] }
  end

  def test_two_link_tlvs_in_one_lsa
    pair
    receive(Fault.lsa(:link_tlv_twice, router_id: '9.9.9.9'))
    r = @b.extended_links(0)['9.9.9.9']
    assert_equal [['10.255.0.7', [15_000]]], r[:links].map { [_1[:link_id], _1[:adj_sids].map { |s| s[:sid] }] }
    assert_equal ['link_tlv_twice'], r[:findings].map { _1[:name] }
  end

  def test_two_link_tlvs_under_strict
    pair(policy: :strict)
    receive(Fault.lsa(:link_tlv_twice, router_id: '9.9.9.9'))
    assert_equal [], @b.extended_links(0)['9.9.9.9'][:links], 'strict: the LSA is ignored'
  end

  def test_detail_decodes_them
    pair
    receive(prefix_lsa(1, 9))
    l = @b.areas[0].lsdb[[10, (7 << 24) | 1, Addr.to_i('9.9.9.9')]]
    d = l.detail
    assert_equal [7, 1, '9.9.9.9/32', 9], [d[:opaque_type], d[:opaque_id], d[:tlvs][0][:prefix], d[:tlvs][0][:subs][0][:sid]]
  end
end
