# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'

class TestCoreLsdb < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  def setup
    @clock = Clock::Fake.new
    @db = Lsdb.new(@clock)
  end

  def lsa(id, seq: 1, age: 0, metric: 10)
    Lsa.router(advr: id, seq: seq, age: age, links: [{ type: 3, id: id, data: 0xffffffff, metric: metric }])
  end

  def test_ages_grow_with_the_clock_and_stop_at_max_age
    @db.install(lsa(1, age: 100))
    @clock.advance(50.9)
    assert_equal 150, @db[lsa(1).key].age
    @clock.advance(10_000)
    assert_equal OSPFv2::MaxAge, @db[lsa(1).key].age
  end

  def test_install_returns_the_previous_copy_with_its_age
    @db.install(lsa(1, seq: 1))
    @clock.advance(30)
    old = @db.install(lsa(1, seq: 2))
    assert_equal 1, old.seq
    assert_equal 30, old.age
    assert_equal 2, @db[lsa(1).key].seq
    assert_equal 0, @db.since_installed(lsa(1).key)
  end

  def test_max_age_entries_appear_when_lsas_expire
    @db.install(lsa(1, age: OSPFv2::MaxAge - 10))
    @db.install(lsa(2, age: 0))
    assert_equal [], @db.max_age_entries
    @clock.advance(9.5)
    assert_equal [], @db.max_age_entries
    @clock.advance(0.5)
    assert_equal [lsa(1).key], @db.max_age_entries.map(&:key)
    @clock.advance(OSPFv2::MaxAge)
    assert_equal [lsa(1).key, lsa(2).key].sort, @db.max_age_entries.map(&:key).sort
  end

  def test_a_fresh_copy_takes_an_lsa_off_the_expired_list
    @db.install(lsa(1, age: OSPFv2::MaxAge - 1))
    @clock.advance(2)
    assert_equal 1, @db.max_age_entries.size
    @db.install(lsa(1, seq: 2))
    assert_equal [], @db.max_age_entries
    @clock.advance(OSPFv2::MaxAge)
    assert_equal 1, @db.max_age_entries.size, 'the new copy expires on its own schedule'
  end

  def test_flushed_lsas_are_expired_at_once_and_delete_clears_them
    @db.install(lsa(1).with_age(OSPFv2::MaxAge))
    assert_equal 1, @db.max_age_entries.size
    @db.delete(lsa(1).key)
    assert_equal [], @db.max_age_entries
    assert @db.empty?
  end

  def test_contents_changed
    a = lsa(1, seq: 1)
    assert Lsdb.contents_changed?(nil, a)
    assert !Lsdb.contents_changed?(a, lsa(1, seq: 2)), 'sequence number alone is not a change'
    assert !Lsdb.contents_changed?(a, a.with_age(500)), 'age alone is not a change'
    assert Lsdb.contents_changed?(a, lsa(1, seq: 2, metric: 20))
    assert Lsdb.contents_changed?(a, a.with_age(OSPFv2::MaxAge))
  end

  def test_checksum_sum
    @db.install(lsa(1))
    @db.install(lsa(2))
    assert_equal lsa(1).checksum + lsa(2).checksum, @db.checksum_sum
  end
end
