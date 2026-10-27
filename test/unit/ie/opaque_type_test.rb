
require "test/unit"
require 'ospfv2/ie/opaque_type'


class TestIeOpaqueType < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert OpaqueType.new
    assert_equal 'OpaqueType: te_lsa', OpaqueType.new.to_s
    assert_equal 'OpaqueType: te_lsa', OpaqueType.new(:te_lsa).to_s
    assert_equal 'OpaqueType: grace_lsa', OpaqueType.new(:grace_lsa).to_s
    assert_equal [1], OpaqueType.new.encode.unpack('C')
    assert_equal [1], OpaqueType.new(:te_lsa).encode.unpack('C')
    assert_equal [1], OpaqueType.new(1).encode.unpack('C')
    assert_equal [3], OpaqueType.new(:grace_lsa).encode.unpack('C')
    assert_equal [3], OpaqueType.new(3).encode.unpack('C')
    assert_equal :te_lsa, OpaqueType.new(1).to_sym
    assert_equal :grace_lsa, OpaqueType.new(3).to_sym
  end
end

