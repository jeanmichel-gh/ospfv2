# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'support/core_lab'

# SR-MPLS origination (RFC 8665 section 7; docs/design/sr-ospf.md,
# step 4, pull request 4): our RI's SR TLVs, the Node-SID, and Adj-SIDs.
class TestCoreSrOrigination < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core
  A = ->(s) { Addr.to_i(s) }
  SR = { srgb: [16_000, 8_000], srlb: [15_000, 1_000] }.freeze
  P2P = { type: :p2p }.freeze

  def setup
    @lab = CoreLab.new
  end

  def sr(r, index, **more)
    r.opaque = true
    r.segment_routing = SR.merge(index: index, **more)
  end

  # a -- b point-to-point, each with its loopback passive.
  def pair
    seg = @lab.segment
    @a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', P2P], [:passive, '1.1.1.1/32'])
    @b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', P2P], [:passive, '2.2.2.2/32'])
    sr(@a, 1)
    sr(@b, 2)
    @lab.start
    assert @lab.run_until(60) { @lab.full?(@a, @b) }
  end

  def links(r, of) = r.extended_links(0).dig(of, :links) || []

  def test_the_ri_carries_srgb_and_srlb
    pair
    assert @lab.run_until(30) { @b.router_information(0).dig('1.1.1.1', :algorithms) }
    assert_equal [[0], [[16_000, 8_000]], [[15_000, 1_000]]],
                 @b.router_information(0)['1.1.1.1'].values_at(:algorithms, :srgb, :srlb)
  end

  def test_the_node_sid
    pair
    assert @lab.run_until(30) { @b.extended_prefixes(0).dig('1.1.1.1', :prefixes, '1.1.1.1/32') }
    p = @b.extended_prefixes(0)['1.1.1.1'][:prefixes]['1.1.1.1/32']
    assert_equal [1, ExtendedPrefix::N_FLAG, 1], p.values_at(:route_type, :flags, :opaque_id)
    assert_equal [{ flags: 0, mt_id: 0, sid: 1, algorithm: 0 }], p[:sids]
  end

  def test_an_adj_sid_per_point_to_point_neighbor
    pair
    assert @lab.run_until(30) { links(@b, '1.1.1.1').any? }
    l = links(@b, '1.1.1.1').first
    assert_equal [1, '2.2.2.2', '10.0.12.1'], l.values_at(:link_type, :link_id, :link_data)
    assert_equal [{ flags: 0x60, mt_id: 0, sid: 15_000, weight: 0 }], l[:adj_sids]
    assert_equal [], l[:lan_adj_sids]
  end

  # RFC 8665 section 7.4.1: withdrawn when the adjacency goes.
  def test_the_adj_sid_goes_with_the_adjacency
    pair
    assert @lab.run_until(30) { links(@b, '1.1.1.1').any? }
    @lab.advance(OSPFv2::MinLSInterval)
    @a.interfaces['eth0'].down
    assert @lab.run_until(60) { @a.areas[0].lsdb.live.none? { _1.advr == A['1.1.1.1'] && _1.ls_id >> 24 == 8 } }
    @a.interfaces['eth0'].up
    assert @lab.run_until(60) { @lab.full?(@a, @b) && links(@b, '1.1.1.1').any? }
    assert_equal [15_000], links(@b, '1.1.1.1').first[:adj_sids].map { _1[:sid] }, 'the label was let go, then taken again'
  end

  def test_no_node_sid_without_a_passive_slash_32
    seg = @lab.segment
    @a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', P2P])
    @b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', P2P])
    sr(@a, 1)
    sr(@b, 2)
    @lab.start
    assert @lab.run_until(60) { @lab.full?(@a, @b) && links(@b, '1.1.1.1').any? }
    assert_nil @b.extended_prefixes(0)['1.1.1.1']
  end

  def test_no_adjacency_sid
    seg = @lab.segment
    @a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', P2P], [:passive, '1.1.1.1/32'])
    @b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', P2P])
    sr(@a, 1, no_adj_sid: ['eth0'])
    sr(@b, 2)
    @lab.start
    assert @lab.run_until(60) { @lab.full?(@a, @b) && @b.extended_prefixes(0)['1.1.1.1'] }
    @lab.advance(10)
    assert_equal [], links(@b, '1.1.1.1')
  end

  # A LAN, c the DR (highest priority), b the BDR, a a DROther. c sends
  # a LAN Adj-SID per neighbor; b an Adj-SID to c and a LAN Adj-SID to a
  # (RFC 8665 section 7.4.2).
  def test_a_broadcast_link
    lan = @lab.segment
    @a = @lab.router('1.1.1.1', [lan, '10.0.0.1/24', { priority: 1 }])
    @b = @lab.router('2.2.2.2', [lan, '10.0.0.2/24', { priority: 2 }])
    @c = @lab.router('3.3.3.3', [lan, '10.0.0.3/24', { priority: 3 }])
    [@a, @b, @c].each_with_index { |r, i| sr(r, i + 1) }
    @lab.start
    ok = @lab.run_until(120) do
      @lab.full?(@a, @c) && @lab.full?(@b, @c) && @lab.full?(@a, @b) &&
        links(@a, '3.3.3.3').first&.dig(:lan_adj_sids)&.size == 2 && links(@a, '2.2.2.2').any?
    end
    assert ok
    dr = links(@a, '3.3.3.3').first
    assert_equal [2, '10.0.0.3', '10.0.0.3', []], dr.values_at(:link_type, :link_id, :link_data, :adj_sids)
    assert_equal %w[1.1.1.1 2.2.2.2], dr[:lan_adj_sids].map { _1[:neighbor] }.sort
    bdr = links(@a, '2.2.2.2').first
    assert_equal [2, '10.0.0.3', '10.0.0.2'], bdr.values_at(:link_type, :link_id, :link_data)
    assert_equal [1, ['1.1.1.1']], [bdr[:adj_sids].size, bdr[:lan_adj_sids].map { _1[:neighbor] }]
  end

  def test_sr_off_flushes_them
    pair
    assert @lab.run_until(30) { @b.extended_prefixes(0)['1.1.1.1'] && links(@b, '1.1.1.1').any? }
    @lab.advance(OSPFv2::MinLSInterval)
    @a.segment_routing = nil
    assert @lab.run_until(60) { @b.extended_prefixes(0)['1.1.1.1'].nil? && links(@b, '1.1.1.1').empty? }
    assert_nil @b.router_information(0)['1.1.1.1'][:algorithms], 'the RI is back to its capabilities'
  end

  def test_types_7_and_8_are_ours
    pair
    assert_raise(ArgumentError) { @a.opaque_lsas = [{ type: 10, area: '0.0.0.0', opaque_type: 7, opaque_id: 9, body: '' }] }
  end
end
