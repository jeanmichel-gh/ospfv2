
require "test/unit"
require 'ie/packet_type'


class TestPacketType < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert PacketType.new
    assert_equal 'PacketType: hello', PacketType.new(:hello).to_s
    assert_equal 'PacketType: dd', PacketType.new(:dd).to_s
    assert_equal 'PacketType: ls_request', PacketType.new(:ls_request).to_s
    assert_equal 'PacketType: ls_update', PacketType.new(:ls_update).to_s
    assert_equal 'PacketType: ls_ack', PacketType.new(:ls_ack).to_s
    assert_equal :hello, PacketType.new(:hello).to_sym
    assert_equal 1, PacketType.new(:hello).to_i
    assert_equal 2, PacketType.new(:dd).to_i
    assert_equal 3, PacketType.new(:ls_request).to_i
    assert_equal 4, PacketType.new(:ls_update).to_i
    assert_equal 5, PacketType.new(:ls_ack).to_i
    assert_equal 1, PacketType.new(1).to_i
    assert_equal 2, PacketType.new(2).to_i
    assert_equal 3, PacketType.new(3).to_i
    assert_equal 4, PacketType.new(4).to_i
    assert_equal 5, PacketType.new(5).to_i
    assert_equal :hello, PacketType.new(:hello).to_sym
    assert_equal :dd, PacketType.new(:dd).to_sym
    assert_equal :ls_request, PacketType.new(:ls_request).to_sym
    assert_equal :ls_update, PacketType.new(:ls_update).to_sym
    assert_equal :ls_ack, PacketType.new(:ls_ack).to_sym
  end
end

