require "test/unit"

require "ie/interface_mtu"

class TestIeInterfaceMtu < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert InterfaceMtu
    assert_equal( '05dc', InterfaceMtu.new.to_shex)
    assert_equal( 'InterfaceMtu: 1500', InterfaceMtu.new.to_s)
    assert_equal( 1500, InterfaceMtu.new.to_i)
    assert_equal( '05c4', InterfaceMtu.new(1476).to_shex)
    assert_equal( 'InterfaceMtu: 255', InterfaceMtu.new(255).to_s)
    assert_equal( 255, InterfaceMtu.new(255).to_i)
    assert_raise(RuntimeError)  { InterfaceMtu.new 0xffffffff }
    assert_raise(RuntimeError)  { InterfaceMtu.new 0xfffffff }
    assert_raise(RuntimeError)  { InterfaceMtu.new 0x1ffffff }
    assert_raise(RuntimeError)  { InterfaceMtu.new( -1) }
    assert_equal( 'InterfaceMtu: 65535', InterfaceMtu.new(0xffff).to_s)
    assert_equal( 'ffff', InterfaceMtu.new(0xffff).to_shex)
    assert_equal( 72, InterfaceMtu.new.number_of_lsa)
  end
end
