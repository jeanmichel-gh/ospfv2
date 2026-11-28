# frozen_string_literal: true

require 'test/unit'
require 'support/frr_lab'
require 'ospfv2/core'

# The core router against FRRouting's ospfd over real raw sockets, one
# network namespace each. Opt in with OSPFV2_FRR=1 as root with FRR
# installed (CI does this in its interop job):
#
#   sudo OSPFV2_FRR=1 ruby -Ilib -Itest test/integration/frr_interop_test.rb
class TestFrrInterop < Test::Unit::TestCase
  MD5 = ['ip ospf authentication message-digest', 'ip ospf message-digest-key 1 md5 secret'].freeze
  EXPECTED_LSDB = [[1, '1.1.1.1', '1.1.1.1'], [1, '2.2.2.2', '2.2.2.2']].freeze

  def setup
    ok, why = FrrLab.available?
    omit(why) unless ok
    @lab = FrrLab.new("ospfv2-#{Process.pid % 1000}-#{name.hash.abs % 1000}")
  end

  def teardown
    @lab&.stop
  end

  def full_both_ways
    @lab.wait_for(30) { @lab.frr_neighbor_state == 'Full' && @lab.core_neighbor_state == 'full' }
  end

  def assert_synced(network_lsa)
    expected = EXPECTED_LSDB + (network_lsa ? [[2, '10.0.12.2', '2.2.2.2']] : [])
    ok = @lab.wait_for(20) { @lab.core_lsdb == expected.sort && @lab.frr_lsdb == expected.sort }
    assert ok, "core #{@lab.core_lsdb.inspect}\nfrr  #{@lab.frr_lsdb.inspect}\n#{@lab.core_log.lines.last(20).join}"
  end

  def assert_full
    assert full_both_ways, "frr #{@lab.frr_neighbor_state.inspect}, core #{@lab.core_neighbor_state.inspect}\n" \
                           "#{@lab.core_log.lines.last(20).join}"
  end

  def test_broadcast_without_authentication
    @lab.start
    assert_full
    assert_synced(true)
  end

  def test_point_to_point_without_authentication
    @lab.start(p2p: true)
    assert_full
    assert_synced(false)
  end

  def test_md5
    @lab.start(frr_interface: MD5, core_interface: { auth: { type: 'md5', keys: { '1' => 'secret' } } })
    assert_full
    assert_synced(true)
    assert_equal 0, @lab.core_stat(:drop_auth)
    assert_match(/Algorithm:MD5/, @lab.vtysh('show ip ospf interface veth0'))
  end

  def test_md5_wrong_key
    @lab.start(frr_interface: MD5, core_interface: { auth: { type: 'md5', keys: { '1' => 'wrong' } } })
    sleep 8
    assert_nil @lab.frr_neighbor_state
    assert_nil @lab.core_neighbor_state
    assert_operator @lab.core_stat(:drop_auth), :>, 3
    assert_match(/digest mismatch/, @lab.core_log)
  end

  def test_md5_two_keys
    # FRR 8.4 signs with its newest key and checks what it receives
    # against that key only, whatever key ID the packet names. RFC 2328 D.3
    # asks receivers to accept every valid key, which we do; so during a
    # rollover with FRR, move both sides to the new send key together.
    @lab.start(frr_interface: MD5 + ['ip ospf message-digest-key 2 md5 newer'],
               core_interface: { auth: { type: 'md5', keys: { '1' => 'secret', '2' => 'newer' } } })
    assert_full
    assert_synced(true)
  end

  # ---- opaque LSAs (RFC 5250; docs/design/sr-ospf.md, step 1)

  FRR_OPAQUE = ['capability opaque', 'router-info area'].freeze
  # Both opaque: Full, and each lists the other's Router Information
  # LSA, the type 10 4.0.0.0 that each sends (ospfd's since step 2).
  def test_opaque_lsas_both_ways
    @lab.start(frr_ospf: FRR_OPAQUE, core: { opaque: true })
    assert_full
    ok = @lab.wait_for(20) do
      @lab.core_lsdb.include?([10, '4.0.0.0', '2.2.2.2']) && @lab.frr_opaque_area.include?(['4.0.0.0', '1.1.1.1'])
    end
    assert ok, "core #{@lab.core_lsdb.inspect}\nfrr  #{@lab.frr_opaque_area.inspect}\n#{@lab.core_log.lines.last(20).join}"
    assert_equal [true], @lab.core_state['neighbors'].map { _1['opaque'] }, 'FRR set O in its DDs'
  end

  # FRR opaque, ospfd not: FRR offers no opaque LSA to a neighbor
  # without O (RFC 5250 section 3.1), so the two reach Full, as they did
  # before this step. Measured on FRR 10.5.1, 2026-11-27.
  def test_frr_opaque_and_ospfd_not
    @lab.start(frr_ospf: FRR_OPAQUE)
    assert_full
    assert_synced(true)
    assert_equal 0, @lab.core_stat(:finding_dd_unsupported_type)
    # show.neighbors says FRR set O; ospfd, opaque off, ignores it.
    assert_equal [true], @lab.core_state['neighbors'].map { _1['opaque'] }, 'FRR sets O in its DDs'
  end

  # ---- Router Information (RFC 7770; docs/design/sr-ospf.md, step 2)

  FRR_SR = FRR_OPAQUE + ['segment-routing on', 'segment-routing global-block 18000 25999 local-block 14000 14999']
  CORE_SR = { algorithms: [0], srgb: [[16_000, 8_000]], srlb: [[15_000, 1_000]] }.freeze

  # Each decodes the other's: FRR lists ospfd's SRGB and SRLB in its own
  # JSON; ospfd reads FRR's, and FRR's octets go through ospfd's codec
  # unchanged.
  def test_router_information_both_ways
    @lab.start(frr_ospf: FRR_SR, core: { opaque: true, sr: CORE_SR })
    assert_full
    ours = nil
    ok = @lab.wait_for(20) do
      ours = @lab.frr_json('show ip ospf database opaque-area 4.0.0.0 adv-router 1.1.1.1')
                 .dig('areaLocalOpaqueLsa', 'areas', '0.0.0.0', 0, 'opaqueValues', 'routerInformation')
      theirs = @lab.core_state.dig('router_information', '2.2.2.2')
      ours&.dig('segmentRouting', 'srgb') && theirs&.dig('algorithms')
    end
    assert ok, "frr #{ours.inspect}\ncore #{@lab.core_state['router_information'].inspect}"
    assert_equal({ 'upperBound' => 23_999, 'lowerBound' => 16_000 }, ours.dig('segmentRouting', 'srgb'))
    assert_equal({ 'upperBound' => 15_999, 'lowerBound' => 15_000 }, ours.dig('segmentRouting', 'srlb'))
    theirs = @lab.core_state.dig('router_information', '2.2.2.2')
    assert_equal [[0], [[18_000, 8_000]], [[14_000, 1_000]], []], theirs.values_at('algorithms', 'srgb', 'srlb', 'findings')
    hex = @lab.core_state.dig('lsas', '0.0.0.0').find { _1[0, 40].then { |h| h[6, 2] == '0a' && h[8, 8] == '04000000' && h[16, 8] == '02020202' } }
    lsa = OSPFv2::Core::Lsa.new([hex].pack('H*'))
    assert_equal lsa.body, OSPFv2::Core::RouterInformation::Body.new(lsa.body).encode, "FRR's RI: #{lsa.body.unpack1('H*')}"
  end

  # ---- extended prefix and link (RFC 7684; docs/design/sr-ospf.md, step 3)

  # ospfd reads FRR's Prefix-SID for its loopback and its Adj-SID to
  # ospfd, and FRR's octets go through ospfd's codec unchanged. They are
  # printed (notify), to be kept as unit test octets.
  def test_frr_s_extended_lsas
    @lab.start(frr_ospf: FRR_SR + ['segment-routing prefix 2.2.2.2/32 index 2'], core: { opaque: true, sr: CORE_SR })
    assert_full
    ok = @lab.wait_for(20) do
      @lab.core_state.dig('extended_prefixes', '2.2.2.2', 'prefixes', '2.2.2.2/32') &&
        @lab.core_state.dig('extended_links', '2.2.2.2', 'links')&.any?
    end
    assert ok, @lab.core_state.slice('extended_prefixes', 'extended_links').inspect
    pfx = @lab.core_state.dig('extended_prefixes', '2.2.2.2', 'prefixes', '2.2.2.2/32')
    assert_equal [2], pfx['sids'].map { _1['sid'] }
    link = @lab.core_state.dig('extended_links', '2.2.2.2', 'links').first
    refute_empty link['adj_sids'] + link['lan_adj_sids'], link.inspect
    [[7, OSPFv2::Core::ExtendedPrefix::Body], [8, OSPFv2::Core::ExtendedLink::Body]].each do |ot, klass|
      @lab.core_state.dig('lsas', '0.0.0.0').each do |hex|
        lsa = OSPFv2::Core::Lsa.new([hex].pack('H*'))
        next unless lsa.type == 10 && lsa.ls_id >> 24 == ot && lsa.advr == OSPFv2::Core::Addr.to_i('2.2.2.2')
        notify("FRR opaque type #{ot} #{OSPFv2::Core::Addr.to_s(lsa.ls_id)}: #{lsa.body.unpack1('H*')}")
        assert_equal lsa.body, klass.new(lsa.body).encode, "FRR's type #{ot}: #{lsa.body.unpack1('H*')}"
      end
    end
  end

  # ---- SR-MPLS origination (docs/design/sr-ospf.md, step 4, PR 4)

  # FRR's SR database lists ospfd with its SRGB and SRLB, its Node-SID
  # (index 1 on 1.1.1.1/32) and an Adj-SID from ospfd's SRLB.
  def test_frr_reads_ospfd_s_sr
    @lab.start(frr_ospf: FRR_SR + ['segment-routing prefix 2.2.2.2/32 index 2'],
               core: { opaque: true, passive: ['lo', '1.1.1.1/32'],
                       segment_routing: { srgb: [16_000, 8_000], srlb: [15_000, 1_000], index: 1 } })
    assert_full
    node = nil
    ok = @lab.wait_for(30) do
      node = Array(@lab.frr_json('show ip ospf database segment-routing')['srNodes']).find { _1['routerID'] == '1.1.1.1' }
      node && Array(node['extendedPrefix']).any? && Array(node['extendedLink']).any?
    end
    assert ok, "FRR's view of 1.1.1.1: #{node.inspect}\n#{@lab.vtysh('show ip ospf database segment-routing json')}"
    assert_equal [16_000, 8_000, 15_000, 1_000], node.values_at('srgbLabel', 'srgbSize', 'srlbLabel', 'srlbSize')
    assert_equal [['1.1.1.1/32', 1]], node['extendedPrefix'].map { _1.values_at('prefix', 'sid') }
    # FRR 10.5.1 lists ospfd's one Adj-SID, and a second entry with sid 0
    # and next hop 0.0.0.0: an empty slot where FRR keeps a backup
    # Adj-SID, which ospfd does not send (measured 2026-11-27).
    sids = node['extendedLink'].map { _1['sid'] }
    assert_equal [15_000], sids.reject(&:zero?), node['extendedLink'].inspect
    notify("FRR's SR node 1.1.1.1: #{JSON.generate(node)}")
  end

  # ---- the label calculation (docs/design/sr-ospf.md, step 4, PR 5)

  # ospfd takes FRR's index 2 in its own block, 16002, and pops it toward
  # FRR, which advertised it with NP clear. FRR takes ospfd's index 1 in
  # its block, 18001, and pops it toward ospfd.
  def test_labels_match
    @lab.start(frr_ospf: FRR_SR + ['segment-routing prefix 2.2.2.2/32 index 2'],
               core: { opaque: true, passive: ['lo', '1.1.1.1/32'],
                       segment_routing: { srgb: [16_000, 8_000], srlb: [15_000, 1_000], index: 1 } })
    assert_full
    ours = nil
    ok = @lab.wait_for(30) { ours = @lab.core_state['labels']&.find { _1['label'] == 16_002 } }
    assert ok, "core labels #{@lab.core_state['labels'].inspect}"
    assert_equal ['php', '2.2.2.2/32', [3]], [ours['op'], ours['fec'], ours['next_hops'].map { _1['out_label'] }]
    frr = nil
    ok = @lab.wait_for(30) { frr = @lab.frr_json('show mpls table')['18001'] }
    notify("FRR's mpls table: #{@lab.vtysh('show mpls table json')}")
    assert ok, "FRR's mpls table: #{@lab.vtysh('show mpls table json')}"
    out = Array(frr['nexthops']).map { _1['outLabel'] || _1['outLabelStack'] }
    assert_equal [[3]], out.map { Array(_1) }, frr.inspect
  end

  def test_ospfd_and_ospf_cli
    @lab.start(frr_interface: MD5, ospfd: [
                 'set routing-options router-id 1.1.1.1',
                 'set protocols ospf area 0 interface veth0 hello-interval 1',
                 'set protocols ospf area 0 interface veth0 dead-interval 4',
                 'set protocols ospf area 0 interface veth0 authentication md5 1 key secret',
                 'set protocols ospf area 0 interface lo passive'
               ])
    ok = @lab.wait_for(30) { @lab.frr_neighbor_state == 'Full' && @lab.cli('show ospf neighbor').include?('Full') }
    assert ok, "frr #{@lab.frr_neighbor_state.inspect}\n#{@lab.cli('show ospf neighbor')}\n#{@lab.core_log.lines.last(20).join}"
    assert_match(/2\.2\.2\.2\s+1\s+FULL\/DR/, @lab.cli('show ip ospf neighbor'))
    assert @lab.wait_for(15) { @lab.core_kernel_routes == ['2.2.2.2 via 10.0.12.2 dev veth0 metric 20'] },
           "kernel: #{@lab.core_kernel_routes.inspect}"
    assert_match(%r{^2\.2\.2\.2/32\s+\*\[OSPF/10\] metric 10\n\s+>  to 10\.0\.12\.2 via veth0$},
                 @lab.cli('show route protocol ospf'))

    out = @lab.cli('configure', 'set protocols ospf area 0 interface veth0 metric 33', 'commit')
    assert_match(/commit complete/, out)
    seen = @lab.wait_for(15) { @lab.vtysh('show ip ospf database router 1.1.1.1').include?('TOS 0 Metric: 33') }
    assert seen, 'FRR sees the new cost'
    assert_equal 'Full', @lab.frr_neighbor_state, 'a cost change keeps the adjacency'
    assert_match(/1\.1\.1\.1\s+1\.1\.1\.1/, @lab.vtysh('show ip ospf database'))
  end

  def test_simple_password
    @lab.start(frr_interface: ['ip ospf authentication', 'ip ospf authentication-key pw'],
               core_interface: { auth: { type: 'simple', password: 'pw' } })
    assert_full
    assert_synced(true)
  end
end
