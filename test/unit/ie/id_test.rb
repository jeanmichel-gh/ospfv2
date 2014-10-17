
require "test/unit"
require 'ie/id.rb'

class TestIeId < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert Id.new
    assert_equal 'Id: 0.0.0.0', Id.new.to_s
    assert_equal 'Id: 0.0.0.0', Id.new.to_s
    assert_equal 'Id: 1.1.1.1', Id.new('1.1.1.1').to_s
    assert_equal 'Id: 1.1.1.1', Id.new(0x01010101).to_s
    assert_equal 'Id: 1.1.1.1', Id.new(IPAddr.new('1.1.1.1')).to_s
    assert_equal '0a000001', Id.new(0x0a000001).to_shex
    assert_equal '0a000001', Id.new(Id.new(Id.new(0x0a000001))).to_shex
  end
  def test_new_ntoh
    assert_equal 'Id: 0.0.0.0', Id.new_ntoh(Id.new.enc).to_s
    assert_equal 'Id: 1.1.1.1', Id.new_ntoh(Id.new('1.1.1.1').enc).to_s
  end
end

