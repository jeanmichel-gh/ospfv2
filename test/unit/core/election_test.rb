# frozen_string_literal: true

require 'test/unit'
require 'support/core_lab'

# DR/BDR election and adjacencies on a broadcast segment (RFC 2328 9.4,
# 10.4), on a fake clock.
class TestCoreElection < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  def setup
    @lab = CoreLab.new
    @lan = @lab.segment
  end

  def lan_router(n, **opts)
    @lab.router("#{n}.#{n}.#{n}.#{n}", [@lan, "10.0.0.#{n}/24", opts])
  end

  def roles(*rs)
    rs.to_h { |r| [r.router_id_s, r.interfaces['eth0'].state] }
  end

  def dr_bdr(r)
    i = r.interfaces['eth0']
    [Addr.to_s(i.dr), Addr.to_s(i.bdr)]
  end

  def settle(*rs)
    @lab.run_until(120) { rs.all? { |r| %i[dr backup dr_other].include?(r.interfaces['eth0'].state) } }
    @lab.advance(30)
  end

  def test_highest_router_id_wins_with_equal_priority
    rs = (1..4).map { |n| lan_router(n) }
    @lab.start
    settle(*rs)
    assert_equal({ '1.1.1.1' => :dr_other, '2.2.2.2' => :dr_other, '3.3.3.3' => :backup, '4.4.4.4' => :dr }, roles(*rs))
    assert rs.all? { |r| dr_bdr(r) == ['10.0.0.4', '10.0.0.3'] }, rs.map { |r| dr_bdr(r) }.inspect
  end

  def test_priority_beats_router_id_and_zero_never_wins
    r1 = lan_router(1, priority: 200)
    r2 = lan_router(2, priority: 100)
    r3 = lan_router(3, priority: 0)
    r4 = lan_router(4, priority: 0)
    @lab.start
    settle(r1, r2, r3, r4)
    assert_equal :dr, r1.interfaces['eth0'].state
    assert_equal :backup, r2.interfaces['eth0'].state
    assert_equal :dr_other, r3.interfaces['eth0'].state
    assert_equal :dr_other, r4.interfaces['eth0'].state
  end

  def test_adjacencies_only_with_dr_and_bdr
    rs = (1..4).map { |n| lan_router(n) }
    @lab.start
    settle(*rs)
    @lab.converge(rs, adjacent: [[rs[3], rs[0]], [rs[3], rs[1]], [rs[3], rs[2]], [rs[2], rs[0]], [rs[2], rs[1]]])
    assert_equal({ '2.2.2.2' => :two_way, '3.3.3.3' => :full, '4.4.4.4' => :full }, @lab.states(rs[0]))
    assert_equal({ '1.1.1.1' => :full, '2.2.2.2' => :full, '3.3.3.3' => :full }, @lab.states(rs[3]))

    net = @lab.lsa(rs[0], 2, '10.0.0.4', '4.4.4.4')
    assert net
    assert_equal %w[1.1.1.1 2.2.2.2 3.3.3.3 4.4.4.4], net.network_body[1].map { |r| Addr.to_s(r) }.sort
    rs.each do |r|
      link = @lab.lsa(rs[0], 1, r.router_id_s).router_links.first
      assert_equal [:transit, '10.0.0.4'], [link.type_name, Addr.to_s(link.id)], r.router_id_s
    end
  end

  def test_a_new_higher_router_does_not_preempt_the_dr
    r1 = lan_router(1)
    r2 = lan_router(2)
    @lab.start
    settle(r1, r2)
    assert_equal :dr, r2.interfaces['eth0'].state

    r9 = lan_router(9, priority: 255)
    r9.start
    settle(r1, r2, r9)
    @lab.advance(60)
    # Neither role is preempted (RFC 2328 9.4 step 2 and 3).
    assert_equal :dr, r2.interfaces['eth0'].state, 'the DR stays'
    assert_equal :backup, r1.interfaces['eth0'].state, 'the BDR stays'
    assert_equal :dr_other, r9.interfaces['eth0'].state

    # When the DR dies, the BDR takes over and the newcomer becomes BDR.
    @lan.drop_if { |_, from, _| from == '10.0.0.2' }
    @lab.run_until(60) { r1.interfaces['eth0'].state == :dr }
    # r9 learns it is BDR from r1's next hello.
    @lab.run_until(15) { r9.interfaces['eth0'].state == :backup }
  end

  def test_bdr_takes_over_when_the_dr_dies
    rs = (1..4).map { |n| lan_router(n) }
    @lab.start
    settle(*rs)
    @lab.converge(rs, adjacent: [[rs[3], rs[0]], [rs[3], rs[2]]])
    @lan.drop_if { |_, from, _| from == '10.0.0.4' } # DR goes silent
    @lab.run_until(60) { rs[2].interfaces['eth0'].state == :dr }
    @lab.advance(10)
    alive = rs.first(3)
    assert_equal({ '1.1.1.1' => :dr_other, '2.2.2.2' => :backup, '3.3.3.3' => :dr }, roles(*alive))
    @lab.converge(alive, adjacent: [[rs[2], rs[0]], [rs[2], rs[1]], [rs[1], rs[0]]])

    net = @lab.lsa(rs[0], 2, '10.0.0.3', '3.3.3.3')
    assert net, 'the new DR describes the segment'
    assert_equal %w[1.1.1.1 2.2.2.2 3.3.3.3], net.network_body[1].map { |r| Addr.to_s(r) }.sort
    old = @lab.lsa(rs[0], 2, '10.0.0.4', '4.4.4.4')
    assert old.nil? || old.age < OSPFv2::MaxAge, 'the dead DR network-LSA ages out on its own'
  end

  def test_dr_flushes_its_network_lsa_when_alone
    r1 = lan_router(1)
    r2 = lan_router(2)
    @lab.start
    @lab.converge([r1, r2])
    assert @lab.lsa(r1, 2, '10.0.0.2', '2.2.2.2')

    r1.stop
    @lab.run_until(60) { r2.neighbors.empty? }
    @lab.advance(10)
    lsa = r2.area(0).lsdb[[2, Addr.to_i('10.0.0.2'), Addr.to_i('2.2.2.2')]]
    assert lsa.nil? || lsa.max_age?, 'flushed once the segment has no full neighbor'
    links = @lab.lsa(r2, 1, '2.2.2.2').router_links
    assert_equal [:stub], links.map(&:type_name), 'and the link went back to stub'
  end

  def test_waiting_ends_early_when_a_dr_is_seen
    r1 = lan_router(1)
    @lab.start
    settle(r1)
    assert_equal :dr, r1.interfaces['eth0'].state

    r2 = lan_router(2)
    r2.start
    took = @lab.run_until(60) { r2.interfaces['eth0'].state != :waiting }
    assert_operator took, :<, 15, 'BackupSeen cut the 40 s wait short'
    assert_equal :backup, r2.interfaces['eth0'].state
  end

  def test_drothers_stay_two_way
    rs = (1..5).map { |n| lan_router(n) }
    @lab.start
    settle(*rs)
    @lab.advance(60)
    others = rs.first(3)
    others.combination(2).each do |a, b|
      assert_equal :two_way, @lab.neighbor(a, b.router_id_s).state
    end
  end

  def test_flooding_on_a_lan_reaches_everyone
    rs = (1..5).map { |n| lan_router(n) }
    @lab.start
    settle(*rs)
    @lab.converge(rs, adjacent: rs.first(3).map { |r| [r, rs[4]] })
    rs[0].add_interface(name: 'lo1', address: '172.20.0.1/32', passive: true)
    @lab.run_until(10) do
      rs.all? { |r| @lab.lsa(r, 1, '1.1.1.1').router_links.any? { |l| Addr.to_s(l.id) == '172.20.0.1' } }
    end
    @lab.converge(rs, adjacent: rs.first(3).map { |r| [r, rs[4]] })
  end
end
