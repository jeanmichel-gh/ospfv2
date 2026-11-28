# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'support/core_lab'

# The label calculation (docs/design/sr-ospf.md, step 4, "Calculation";
# pull request 5), on the fake clock.
#
#   a ---- b ---- c ---- d      point-to-point, area 0 but where told
#   16000  17000  18000  19000  SRGB starts
#   idx 1  idx 2  idx 3  idx 4  Node-SIDs on each loopback
class TestCoreSrLabels < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core
  P2P = { type: :p2p }.freeze
  L = SrLabels

  def setup
    @lab = CoreLab.new
  end

  def sr(r, start, index, **more)
    r.opaque = true
    r.segment_routing = { srgb: [start, 8_000], srlb: [15_000, 1_000], index: index }.merge(more)
  end

  def line(areas: [0, 0, 0], no_sr: [], **opts)
    s = Array.new(3) { @lab.segment }
    @a = @lab.router('1.1.1.1', [s[0], '10.0.12.1/30', P2P.merge(area: areas[0])], [:passive, '1.1.1.1/32', { area: areas[0] }])
    @b = @lab.router('2.2.2.2', [s[0], '10.0.12.2/30', P2P.merge(area: areas[0])], [s[1], '10.0.23.1/30', P2P.merge(area: areas[1])],
                     [:passive, '2.2.2.2/32', { area: areas[0] }])
    @c = @lab.router('3.3.3.3', [s[1], '10.0.23.2/30', P2P.merge(area: areas[1])], [s[2], '10.0.34.1/30', P2P.merge(area: areas[2])],
                     [:passive, '3.3.3.3/32', { area: areas[1] }])
    @d = @lab.router('4.4.4.4', [s[2], '10.0.34.2/30', P2P.merge(area: areas[2])], [:passive, '4.4.4.4/32', { area: areas[2] }])
    [@a, @b, @c, @d].each_with_index do |r, i|
      # Opaque still, so it floods the others' SR LSAs.
      next r.opaque = true if no_sr.include?(i)
      sr(r, 16_000 + (1000 * i), opts.fetch(:indexes, [1, 2, 3, 4])[i], **opts.fetch(:more, {}).fetch(i, {}))
    end
    @lab.start
    assert @lab.run_until(120) { @lab.full?(@a, @b) && @lab.full?(@b, @c) && @lab.full?(@c, @d) }
  end

  def settle(r, label)
    assert @lab.run_until(60) { r.sr_labels&.entries&.key?(label) }, (r.sr_labels&.problems || []).join("\n")
  end

  def hops(e) = e.next_hops.map { _1[:out_label] }

  def test_swap_along_the_line
    line
    settle(@a, 16_004)
    e = @a.sr_labels.entries[16_004]
    assert_equal [:swap, :prefix_sid, '4.4.4.4/32', [17_004]], [e.op, e.kind, e.fec, hops(e)], 'index 4 in b\'s SRGB'
    settle(@b, 17_004)
    assert_equal [18_004], hops(@b.sr_labels.entries[17_004])
    settle(@c, 18_004)
    assert_equal [:php, [L::IMPLICIT_NULL]], [@c.sr_labels.entries[18_004].op, hops(@c.sr_labels.entries[18_004])], 'd advertised it, NP clear'
  end

  def test_no_label_for_our_own_prefix_with_php
    line
    settle(@a, 16_002)
    refute @a.sr_labels.entries.key?(16_001)
    assert_equal :php, @a.sr_labels.entries[16_002].op
  end

  # d sets NP and E (explicit-null): c sends 0, and d pops its own.
  def test_explicit_null
    line(more: { 3 => { explicit_null: true } })
    settle(@c, 18_004)
    assert_equal [:swap, [L::EXPLICIT_NULL]], [@c.sr_labels.entries[18_004].op, hops(@c.sr_labels.entries[18_004])]
    settle(@d, 19_004)
    assert_equal [:pop, []], [@d.sr_labels.entries[19_004].op, @d.sr_labels.entries[19_004].next_hops]
    assert_equal [18_004], hops(@b.sr_labels.entries[17_004]), 'NP: c does not pop for b'
  end

  # b runs opaque but no SR: a's next hop toward c and d has no SRGB, so
  # no label, and the IP route stays.
  def test_a_neighbor_without_an_srgb
    line(no_sr: [1])
    assert @lab.run_until(60) { @a.sr_labels&.problems&.any? { _1.include?('4.4.4.4/32: neighbor 2.2.2.2 has no SRGB') } }
    refute @a.sr_labels.entries.key?(16_004)
    assert_nil @a.sr_labels.out_labels['4.4.4.4/32']
  end

  def test_adj_sids_pop
    line
    assert @lab.run_until(60) { @a.sr_labels&.entries&.values&.any? { _1.kind == :adj_sid } }
    e = @a.sr_labels.entries.values.find { _1.kind == :adj_sid }
    assert_equal [15_000, :pop, '2.2.2.2', [{ interface: 'eth0', address: '10.0.12.2', out_label: L::IMPLICIT_NULL }]],
                 [e.label, e.op, e.fec, e.next_hops]
  end

  # c and d both take index 3: neither gets a label (RFC 8660 section 2.5,
  # open question 2), and one sr_finding is announced.
  def test_two_prefixes_with_one_index
    line(indexes: [1, 2, 3, 3])
    assert @lab.run_until(60) { @a.sr_labels&.findings&.any? { _1[:name] == 'prefix_sid_duplicate' } }
    refute @a.sr_labels.entries.key?(16_003)
    @lab.advance(30)
    events = @a.events.select { _1.kind == :sr_finding && _1.data[:finding] == 'prefix_sid_duplicate' }
    assert_equal 1, events.size, 'announced once'
    assert_equal ['RFC 8660 2.5', 'no_label'], events.first.data.values_at(:rfc, :action)
  end

  # a and b in area 0, c and d in area 1, b the ABR: b gives a c's and d's
  # SIDs as inter-area, NP set, so a swaps into b's block and b does not
  # pop toward itself (RFC 8665 section 7.2).
  def test_inter_area
    line(areas: [0, 1, 1])
    settle(@a, 16_004)
    assert_equal [17_004], hops(@a.sr_labels.entries[16_004])
    p = @a.extended_prefixes(0).dig('2.2.2.2', :prefixes, '4.4.4.4/32')
    assert_equal 3, p[:route_type]
    assert p[:sids].first[:flags].anybits?(ExtendedPrefix::PrefixSid::NP), 'NP set by the ABR'
    settle(@b, 17_004)
    assert_equal [18_004], hops(@b.sr_labels.entries[17_004])
  end

  # A diamond: a to d through b and c at equal cost, one out-label per
  # next hop, each in that neighbor's block.
  def test_ecmp
    s = Array.new(4) { @lab.segment }
    @a = @lab.router('1.1.1.1', [s[0], '10.0.12.1/30', P2P], [s[1], '10.0.13.1/30', P2P], [:passive, '1.1.1.1/32'])
    @b = @lab.router('2.2.2.2', [s[0], '10.0.12.2/30', P2P], [s[2], '10.0.24.1/30', P2P], [:passive, '2.2.2.2/32'])
    @c = @lab.router('3.3.3.3', [s[1], '10.0.13.2/30', P2P], [s[3], '10.0.34.1/30', P2P], [:passive, '3.3.3.3/32'])
    @d = @lab.router('4.4.4.4', [s[2], '10.0.24.2/30', P2P], [s[3], '10.0.34.2/30', P2P], [:passive, '4.4.4.4/32'])
    [@a, @b, @c, @d].each_with_index { |r, i| sr(r, 16_000 + (1000 * i), i + 1) }
    @lab.start
    settle(@a, 16_004)
    assert @lab.run_until(30) { @a.sr_labels.entries[16_004].next_hops.size == 2 }
    assert_equal [['eth0', 17_004], ['eth1', 18_004]],
                 @a.sr_labels.entries[16_004].next_hops.map { _1.values_at(:interface, :out_label) }.sort
  end

  def test_label_at
    assert_equal [1000, 500, 100, nil], [100, 200, 0, 300].map { L.label_at([[100, 100], [1000, 100], [500, 100]], _1) },
                 'RFC 8665 section 3.2: index 100 is label 1000, index 200 is label 500'
  end
end
