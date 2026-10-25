require 'test/unit'
require 'ospfv2'

# RFC 2328 13: what the LSDB does with LSAs it receives, in particular
# copies of the LSAs we originate that the router floods back.
class TestLsDbFlooding < Test::Unit::TestCase
  include OSPFv2

  def setup
    @db = LSDB::LinkStateDatabase.new
    @db.advertised_routers << '1.1.1.1'
    @ours = Summary.new(advertising_router: '1.1.1.1', network: '30.0.0.0/24', metric: 10)
    @db << @ours
    @ours.retransmit
  end

  def lsu(*lsas)
    LinkStateUpdate.new(router_id: 2, area_id: 0).tap { |u| lsas.each { |l| u.lsas << l } }
  end

  def copy(lsa) = Lsa.factory(lsa.encode)

  def test_echo_of_our_lsa_is_an_implicit_ack
    LsAge.aging :on
    seq = @ours.sequence_number.to_I
    sleep 1.1
    @db.recv_link_state_update(lsu(copy(@ours)))
    assert_equal seq, @ours.sequence_number.to_I, 'an echo must not bump the sequence number'
    assert_operator @ours.ls_age.to_i, :>=, 1, 'an echo must not reset the age'
    assert @ours.ack?, 'an echo acknowledges the LSA'
  ensure
    LsAge.aging :off
  end

  def test_newer_copy_of_our_lsa_makes_us_jump_past_it
    theirs = copy(@ours)
    theirs.sequence_number = 0x80000010
    @db.recv_link_state_update(lsu(theirs))
    assert_equal 0x80000011, @ours.sequence_number.to_I
    refute @ours.ack?, 'the new instance needs flooding'
  end

  def test_older_copy_of_our_lsa_is_ignored
    @ours.force_refresh(0x80000005)
    old = Summary.new(advertising_router: '1.1.1.1', network: '30.0.0.0/24', metric: 10)
    @db.recv_link_state_update(lsu(old))
    assert_equal 0x80000006, @ours.sequence_number.to_I
  end

  def test_unknown_lsa_claiming_to_be_ours_is_flushed
    stray = Summary.new(advertising_router: '1.1.1.1', network: '31.0.0.0/24')
    @db.recv_link_state_update(lsu(stray))
    kept = @db.lookup(stray)
    assert kept.maxaged?
    refute kept.ack?, 'the MaxAge copy is flooded until acked'
  end

  def test_echo_of_flushed_lsa_removes_it
    @ours.maxage
    @db.recv_link_state_update(lsu(copy(@ours)))
    assert_nil @db.lookup(@ours)
  end

  def test_other_routers_keep_the_newest_copy
    a = Summary.new(advertising_router: '9.9.9.9', network: '40.0.0.0/24')
    a.sequence_number = 0x80000005
    @db.recv_link_state_update(lsu(a))
    older = Summary.new(advertising_router: '9.9.9.9', network: '40.0.0.0/24', metric: 99)
    @db.recv_link_state_update(lsu(older))
    assert_equal 0x80000005, @db.lookup(a).sequence_number.to_I
    gone = copy(a)
    gone.maxage
    @db.recv_link_state_update(lsu(gone))
    assert_nil @db.lookup(a)
  end

  def test_dd_requests_only_what_we_lack_or_hold_older
    other = Summary.new(advertising_router: '9.9.9.9', network: '40.0.0.0/24')
    @db << other
    newer = copy(other)
    newer.sequence_number = 0x80000009
    missing = Summary.new(advertising_router: '9.9.9.9', network: '41.0.0.0/24')
    req = {}
    headers = [copy(@ours), copy(other), newer, missing]
    @db.recv_dd(headers, req) # recv_dd only needs #each
    assert_equal [newer.key, missing.key].sort, req.keys.sort
    assert_equal 0x80000001, @ours.sequence_number.to_I, 'describing our own LSA does not reset it'
  end
end
