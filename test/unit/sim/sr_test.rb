# frozen_string_literal: true

require 'test/unit'
require 'ipaddr'
require 'ospfv2/simulator'
require 'ospfv2/web/server'
require 'json'
require_relative '../../support/capture_transport'

# The simulator with SR-MPLS (docs/design/sr-ospf.md, step 5): its
# topology keys, the opaque LSAs it builds, the O bit in its DDs, and its
# API.
class TestSimulatorSr < Test::Unit::TestCase
  include OSPFv2
  A = ->(s) { IPAddr.new(s).to_i }

  def topo(extra = {})
    Topology.from_hash({ 'segment_routing' => {}, 'grid' => { 'columns' => 2, 'rows' => 2, 'sids' => 1 } }.merge(extra))
  end

  def sim(t = topo) = @sim = Simulator.new(t, transport: CaptureTransport.new, min_ls_interval: 0)

  def teardown = @sim&.stop

  def opaque(advr, ls_id) = @sim.ls_db.lookup(:area, ls_id, advr)

  def body(l) = l.decoded

  # ---- the topology

  def test_the_topology_keys
    t = topo('routers' => [{ 'name' => 'edge', 'id' => '10.0.0.1', 'sid' => 9, 'srgb' => { 'start' => 20_000, 'size' => 1000 } }],
             'links' => [%w[edge r2c2]])
    assert_equal({ srgb: [16_000, 8000], srlb: [15_000, 1000] }, t.segment_routing)
    assert_equal [1, 2, 3, 4, 9], t.routers.values.map(&:sid)
    assert_equal [20_000, 1000], t.router('edge').srgb
    assert_equal({ start: 16_000, size: 8000 }, t.to_h.dig(:segment_routing, :srgb))
  end

  def test_bad_sr_keys
    { { 'routers' => [{ 'id' => '1.2.3.4', 'sid' => 1 }] } => /needs a segment_routing section/,
      { 'segment_routing' => { 'srgb' => { 'start' => 15_500, 'size' => 8000 } } } => /overlap/,
      { 'segment_routing' => { 'srgb' => { 'start' => 1_048_000, 'size' => 8000 } } } => /from 16 to 1048575/,
      { 'segment_routing' => { 'bogus' => 1 } } => /unknown key\(s\) bogus/,
      { 'segment_routing' => {}, 'routers' => [{ 'id' => '1.2.3.4', 'sid' => -1 }] } => /an index, 0 or more/ }.each do |h, want|
      e = assert_raise(Topology::Error) { Topology.from_hash(h) }
      assert_match want, e.message, h.inspect
    end
  end

  # ---- the LSAs

  def test_each_router_sends_its_ri
    sim(topo('routers' => [{ 'name' => 'edge', 'id' => '10.0.0.1', 'srgb' => { 'start' => 20_000, 'size' => 1000 } }],
             'links' => [%w[edge r2c2]]))
    ri = body(opaque('0.1.0.1', '4.0.0.0'))
    assert_equal [[0], [[16_000, 8000]], [[15_000, 1000]]],
                 [ri.algorithms, *[Core::RouterInformation::SidLabelRange, Core::RouterInformation::Srlb].map { |k| ri.ranges(k).map { [_1.first, _1.size] } }]
    assert_equal [[20_000, 1000]], body(opaque('10.0.0.1', '4.0.0.0')).ranges(Core::RouterInformation::SidLabelRange).map { [_1.first, _1.size] }
    assert opaque('1.1.1.1', '4.0.0.0'), 'the simulator\'s own router too'
  end

  def test_node_sids_on_the_router_id_s_slash_32
    sim
    p = body(opaque('0.2.0.2', '7.0.0.1')).prefixes.first
    assert_equal ['0.2.0.2/32', Core::ExtendedPrefix::N_FLAG, 4], [p.prefix_s, p.flags, p.sids.first.sid]
    stubs = @sim.ls_db.lookup(:router, '0.2.0.2', '0.2.0.2').links.select { _1.router_link_type.to_i == 3 }
    assert(stubs.any? { _1.link_id.to_ip == '0.2.0.2' && _1.link_data.to_ip == '255.255.255.255' }, 'its /32 is in its router LSA')
  end

  def test_an_adj_sid_per_link_end
    sim
    links = @sim.ls_db.all.select { _1.is_opaque? && _1.opaque_type.to_i == 8 }
    assert_equal 10, links.size, 'four grid links and the attach link, two ends each'
    by = links.group_by { _1.advertising_router.to_ip }
    labels = by['0.1.0.1'].map { body(_1).links.first.adj_sids.first.sid }
    assert_equal [15_000, 15_001, 15_002], labels.sort, 'each from the SRLB, one per link'
    l = body(by['0.1.0.2'].first).links.first
    assert_equal 1, l.link_type
    assert_equal 0x60, l.adj_sids.first.flags
  end

  def test_the_octets_go_through_the_core
    sim
    @sim.ls_db.all.select(&:is_opaque?).each do |l|
      c = Core::Lsa.parse(l.encode)
      assert c.checksum_ok?, l.to_s
      assert_equal l.encode, Lsa.factory(l.encode).encode
      assert_nil c.detail[:error], l.to_s
    end
  end

  def test_without_sr_nothing_is_added
    sim(Topology.from_hash('grid' => { 'columns' => 2, 'rows' => 2 }))
    assert_empty @sim.ls_db.all.select(&:is_opaque?)
    assert_nil @sim.neighbor.dd_options_extra
  end

  def test_the_o_bit_is_in_its_dds_only
    sim
    assert_equal 0x40, @sim.neighbor.dd_options_extra
    refute @sim.neighbor.hello.options.to_i.anybits?(0x40), 'not in Hellos'
  end

  # RFC 8665 section 7.4.1: a link's Adj-SIDs go with it, and come back.
  def test_a_link_down_flushes_its_adj_sids
    sim
    l = @sim.send(:find_link, 'r1c1--r1c2')
    ends = @sim.send(:sr_link_lsas, l)
    assert_equal 2, ends.size
    @sim.link_down('r1c1--r1c2')
    assert(ends.all?(&:maxaged?))
    @sim.link_up('r1c1--r1c2')
    refute(ends.any? { @sim.instance_variable_get(:@flushed_lsas).key?(_1.key) })
  end

  # ---- the API (answers 5 and 6 for routescope)

  def test_lsdb_rows_and_the_graph
    sim
    row = @sim.lsdb_rows(detail: true).find { _1[:ls_id] == '7.0.0.1' && _1[:advertising_router] == '0.1.0.1' }
    assert_equal [:area, 'OpaqArea', 7, 1], row.values_at(:type, :type_name, :opaque_type, :opaque_id)
    assert_equal 'extended-prefix', row.dig(:detail, :tlvs, 0, :name)
    refute @sim.lsdb_rows.find { _1[:type] == :router }.key?(:opaque_type)
    n = @sim.snapshot[:graph][:nodes].find { _1[:id] == 'r2c1' }
    assert_equal [[{ start: 16_000, size: 8000 }], 3], n.values_at(:srgb, :sid)
    refute @sim.snapshot[:graph][:nodes].find { _1[:id] == 'sim' }.key?(:sid)
  end

  def test_lsa_actions_take_opaque_lsas
    sim
    seq = opaque('0.1.0.1', '4.0.0.0').sequence_number.to_I
    row = @sim.lsa_refresh('area', '4.0.0.0', '0.1.0.1')
    assert_equal format('0x%08x', seq + 1), row[:seq]
    row = @sim.lsa_flush('area', '8.0.0.1', '0.1.0.1')
    assert_equal [3600, true], row.values_at(:age, :flushed)
  end
end
