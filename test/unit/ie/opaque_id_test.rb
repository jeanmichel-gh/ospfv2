require "test/unit"

require "ie/opaque_id"

class TestIeOpaqueId < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert OpaqueId.new
    assert_equal( '000000', OpaqueId.new.to_shex)
    assert_equal( 'OpaqueId: 0', OpaqueId.new.to_s)
    assert_equal( 0, OpaqueId.new.to_i)
    assert_equal( '0000ff', OpaqueId.new(255).to_shex)
    assert_equal( 'OpaqueId: 255', OpaqueId.new(255).to_s)
    assert_equal( 255, OpaqueId.new(255).to_i)
    assert_raise(RuntimeError)  { OpaqueId.new 0xffffffff }
    assert_raise(RuntimeError)  { OpaqueId.new 0xfffffff }
    assert_raise(RuntimeError)  { OpaqueId.new 0x1ffffff }
    assert_raise(RuntimeError)  { OpaqueId.new( -1) }
    assert_equal( 'OpaqueId: 16777215', OpaqueId.new(0x0ffffff).to_s)
    assert_equal( '0fffff', OpaqueId.new(0xfffff).to_shex)
  end
end
