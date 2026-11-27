# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'support/core_lab'

# The drops of receive_update and accept_dd, counted by their
# Validation finding (docs/design/sr-ospf.md, step 0). Nothing else
# about them changes: every policy drops.
class TestCoreFindings < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  def pair(area: 0, stub: false)
    @lab = CoreLab.new
    seg = @lab.segment
    p2p = { type: :p2p, area: area }
    @a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', p2p])
    @b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', p2p])
    [@a, @b].each { |r| r.area_options = { area => { stub: {} } } } if stub
    @lab.start
    assert @lab.run_until(60) { @lab.full?(@a, @b) }
    @nbr = @lab.neighbor(@b, '1.1.1.1')
  end

  def lsa(type, ls_id = '50.0.0.0')
    Lsa.build(type: type, ls_id: ls_id, advr: '1.1.1.1', seq: Lsa::INITIAL_SEQ, body: [0xffffff00, 20, 0, 0].pack('N4'))
  end

  def stats = @b.interfaces['eth0'].stats

  def test_an_external_in_a_stub_area
    pair(area: 1, stub: true)
    @b.receive_update(@nbr, Wire::LinkStateUpdate.new(lsas: [lsa(5)]))
    assert_equal [1, 1], stats.values_at(:drop_lsa, :finding_as_external_in_stub)
  end

  def test_a_type_7_outside_an_nssa_and_an_unknown_type
    pair
    @b.receive_update(@nbr, Wire::LinkStateUpdate.new(lsas: [lsa(7), lsa(10, '4.0.0.0')]))
    assert_equal [2, 1, 1], stats.values_at(:drop_lsa, :finding_nssa_outside_nssa, :finding_unsupported_lsa_type)
  end

  def test_a_dd_that_offers_an_unknown_type
    pair
    dd = Wire::DatabaseDescription.new(mtu: 1500, options: 0x42, flags: 0, seq: 1, headers: [lsa(10, '4.0.0.0').header])
    @nbr.send(:accept_dd, dd)
    assert_equal 1, stats[:finding_dd_unsupported_type]
    assert_match(/SeqNumberMismatch \(unsupported LSA type 10\)/, @lab.log.join("\n"))
  end

  def test_the_policy_is_checked
    assert_equal :rfc, Instance.new(router_id: '1.1.1.1', loop: CoreLab.new.loop).receive_policy
    assert_equal :strict, Instance.new(router_id: '1.1.1.1', loop: CoreLab.new.loop, receive_policy: 'strict').receive_policy
    assert_raise(ArgumentError) { Instance.new(router_id: '1.1.1.1', loop: CoreLab.new.loop, receive_policy: :loose) }
  end
end
