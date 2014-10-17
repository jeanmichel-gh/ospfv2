
require "test/unit"
require 'ie/au_type'

class TestIeAuType < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert AuType.new
    assert_equal 'AuType: null authentication', AuType.new(0).to_s
    assert_equal 'AuType: simple password', AuType.new(1).to_s
    assert_equal 'AuType: cryptographic authentication', AuType.new(2).to_s
    assert_equal 'AuType: unknown', AuType.new(3).to_s
    assert_equal 0, AuType.new(0).to_i
    assert_equal 1, AuType.new(1).to_i
    assert_equal 2, AuType.new(2).to_i
    assert_equal 3, AuType.new(3).to_i
  end
end
