
require "test/unit"
require 'packet/ospf_packet'

class TestOspfPacket < Test::Unit::TestCase
  include OSPFv2
  
  def test_new
    p1 = OspfPacket.new :version=>4, :router_id=>'1.1.1.1', :area_id=>'2.2.2.2', :packet_type=> :hello
    p2 = OspfPacket.new p1.to_hash
    p3 = OspfPacket.new p1.encode
    assert_equal p1.to_hash, p2.to_hash
    assert_equal p1.to_shex, p2.to_shex
    assert_equal p2.to_shex, p3.to_shex
    assert_equal 'RouterId: 1.1.1.1', p1.router_id.to_s
    assert_equal 'AreaId: 2.2.2.2'  , p1.area_id.to_s
    assert_equal 'PacketType: hello', p1.packet_type.to_s
    assert_equal 'AuType: null authentication', p1.au_type.to_s
    
    p1.router_id = '2.2.2.2'
    assert_equal 'RouterId: 2.2.2.2', p1.router_id.to_s
    p1.area_id = '3.3.3.3'
    assert_equal 'AreaId: 3.3.3.3', p1.area_id.to_s
   end
   
   def _test_factory_hello_from_hash
  
   # :ls_update 
   # :ls_ack    
   
     hello_packet = Hello.new :packet_type=> :hello, :router_id=>0x0a010101, :area_id=>255
     p hello_packet
     puts hello_packet
     packet = OspfPacket.factory(hello_packet.encode)
     assert_equal OSPFv2::Hello, packet.class
     assert_equal hello_packet.to_shex, packet.to_shex
   end
   
   def test_factory_lsr_from_bits
     s = '0203003cc0a801c800000000273700000000000000000000000000010202020202020202000000010303030303030303000000010000000100000001'
   end
   def test_factory_lsr_from_hash
   end
   
   def test_factory_lsu
     
     s = '0204006cc0a801c8000000007dd8000000000000000000000000000200012201c0a801c8c0a801c88000014679c4003000000002c7000000ffffff0003000001c0a801c8c0a801c80200000a00012202c0a801c8c0a801c880000001e0bb0020ffffff00c0a801c801010101'
     assert_equal LinkStateUpdate, (pq = OspfPacket.factory([s].pack('H*'))).class
    # puts pq
     
   end
   
   def test_dd_from_bits
   end
   
   def test_factory_dd_from_bits
     s = '02020020c0a801c800000000ce4c0000000000000000000005dc4207c0a46498'
     assert_equal DatabaseDescription, (pq = OspfPacket.factory([s].pack('H*'))).class
   end
   
   def test_dd_from_hash
     h = {:packet_type=>:dd, :area_id=>"0.0.0.0", :imms=>7, :au_type=>:null, :router_id=>"192.168.1.200", :dd_sequence_number=>1, :ospf_version=>2, :interface_mtu=>1500, :options=>0}
     dd = OspfPacket.factory :packet_type=>:dd, :area_id=>"0.0.0.0", :imms=>7, :au_type=>:null, :router_id=>"192.168.1.200", :dd_sequence_number=>1, :ospf_version=>2, :interface_mtu=>1500, :lsas=>[], :options=>0, :csum=>9671
     assert_equal DatabaseDescription, dd.class
     assert_equal h.merge(:lsas=>[]), dd.to_hash
   end

end

__END__

puts OspfPacket.factory([@s].pack('H*'))

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Version #   |     Type      |         Packet length         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Router ID                            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           Area ID                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|           Checksum            |             AuType            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Authentication                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Authentication                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

"02 01 0018 01010101 02020202 f7e0 00000000000000000000"
"02 s00 0018 01010101 02020202 f7e1 00000000000000000000"