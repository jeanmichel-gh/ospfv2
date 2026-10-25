require "test/unit"

require 'ospfv2'

class TestIeLsAge < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert LsAge.new
    assert_equal( 0, LsAge.new.to_i)
    assert_equal( 1, LsAge.new(1).to_i)
  end
  def test_compare
    a1 = LsAge.new
    a2 = LsAge.new(2)
    assert( ! (a1 == a2), "should not be equal")
    assert(   (a1 < a2), "a1 is more recent, i.e smaller age")
  end
  def test_minus
    a1 = LsAge.new
    a2 = LsAge.new(2)
    assert_equal( -2, a1 - a2)
    assert_equal(  2, a2 - a1)
  end
  def test_maxage
    a1 = LsAge.new
    assert_equal( 0, a1.to_i)
    assert_equal( 3600, a1.maxage)
    assert( a1.maxaged?, 'should be maxaged!')
  end
  def test_aging_is_shared_with_lsa_subclass
    LsAge.aging :on
    assert Lsa::LsAge.aging?, 'Lsa uses a subclass of LsAge; both must see the switch'
    a = Lsa::LsAge.new(5)
    sleep 1.1
    assert_operator a.to_i, :>=, 6
    assert_equal [a.to_i].pack('n'), a.encode, 'the current age goes on the wire'
  ensure
    LsAge.aging :off
  end

  def test_age_is_capped_at_maxage
    a = LsAge.new(3599)
    LsAge.aging :on
    sleep 1.1
    assert_equal 3600, a.to_i
    assert a.maxaged?
  ensure
    LsAge.aging :off
  end

  def test_aging
    a1 = LsAge.new(20)
    sleep 1.1
    assert_equal( 20, a1.to_i)
    assert( ! LsAge.aging?)
    assert_equal( 20, a1.to_i)
    LsAge.aging :on
    assert LsAge.aging?
    assert_equal( 20, a1.to_i)
    sleep 1.1
    assert( LsAge.aging?)
    assert_equal( 21, a1.to_i)
    LsAge.aging :off
    assert( ! LsAge.aging?)
    assert_equal( 21, a1.to_i, 'freezing holds the age, it does not reset it')
    sleep 1.1
    assert_equal( 21, a1.to_i, 'a frozen age stays put')
  end
end