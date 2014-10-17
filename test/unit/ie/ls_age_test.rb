require "test/unit"

require "ie/ls_age"

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
    assert_equal( 20, a1.to_i)
  end
end