#TODO: finish external LSA and add Unit Tests.

require "test/unit"

# require "lsa/external"
require_relative "../../../lib/lsa/external"

class TestLsaExternal < Test::Unit::TestCase
  include OSPFv2
  def setup
    AsExternal.reset
  end
  def tests
    h_lsa = {
      :advertising_router=>"1.1.1.1",
      :ls_id=>"10.0.0.0",
      :netmask => "255.255.255.0",
      :forwarding_address => "1.2.3.0",
      :metric => 1,
      :type => :e2,
      :tag=> 255
    }
    ext = OSPFv2::AsExternal.new(h_lsa)
    assert_equal '000000050a0000000101010180000001b40b0024ffffff008000000101020300000000ff', ext.to_shex
    
  
    ext.type=:e1
    assert_equal '000000050a0000000101010180000001310f0024ffffff000000000101020300000000ff', ext.to_shex
    ext.metric=10
    assert_equal '000000050a00000001010101800000018bab0024ffffff000000000a01020300000000ff', ext.to_shex
    ext.tag=0xff00
    assert_equal '000000050a00000001010101800000018bab0024ffffff000000000a010203000000ff00', ext.to_shex
    ext.forwarding_address='5.4.3.2'
    assert_equal '000000050a0000000101010180000001eb430024ffffff000000000a050403020000ff00', ext.to_shex
    h_lsa = {
      :advertising_router=>"1.1.1.1", :network => '10.0.0.0/24',
      :forwarding_address => "1.2.3.0",
      :metric => 1,
      :type => :e2,
      :tag=> 255
    }
    ext2 = OSPFv2::AsExternal.new(h_lsa)
    ext2.type=:e1
    ext2.metric=10
    ext2.tag=0xff00
    ext2.forwarding_address='5.4.3.2'
    assert_equal ext.encode, ext2.encode
  end
  
  def test_count
    AsExternal.new_lsdb
    assert_equal "50.0.0.#{AsExternal.count}/24", AsExternal.network
    AsExternal.new_lsdb
    assert_equal 2, AsExternal.count
    assert_equal "50.0.0.#{AsExternal.count}/24", AsExternal.network
  end
  


  def test_new_lsdb
   ( AsExternal.new_lsdb :advertising_router=> 1)
   ( AsExternal.new_lsdb :advertising_router=> 1)
   assert_equal 2, AsExternal.count
  end
  
  def test_add_mt
    h_lsa = {
      :advertising_router=>"1.1.1.1", :network => '10.0.0.0/24',
      :forwarding_address => "1.2.3.0",
      :metric => 0,
      :type => :e2,
      :tag=> 255
    }
    ext = OSPFv2::AsExternal.new(h_lsa)
    
    ext << {
      :id=>20,
      :forwarding_address => "1.2.3.0",
      :metric => 20,
      :type => :e2,
      :tag=> 255
    }
        
    puts ext
  end

  def test_add_mt
    h_lsa = {
      :advertising_router=>"1.1.1.1", :network => '10.0.0.0/24',
      :forwarding_address => "1.2.3.0",
      :metric => 0,
      :type => :e2,
      :tag=> 255,
      
      :mt_metrics => [
        {:mt_id=>20,
        :forwarding_address => "1.2.3.0",
        :metric => 20,
        :type => :e2,
        :tag=> 255
        },
        {:mt_id=>33,
        :forwarding_address => "1.2.3.0",
        :metric => 30,
        :type => :e1,
        :tag=> 255
        }
      ]
    }
    ext = OSPFv2::AsExternal.new(h_lsa)
    
    ext << {
      :mt_id=>20,
      :forwarding_address => "1.2.3.0",
      :metric => 20,
      :type => :e2,
      :tag=> 255
    }
    
    assert_equal ext.encode, AsExternal.new(ext).encode
    
  end

end

__END__


R1#show ip ospf database external      

            OSPF Router with ID (1.1.1.1) (Process ID 1)

                Type-5 AS External Link States

  Routing Bit Set on this LSA
  LS age: 12
  Options: (No TOS-capability, No DC)
  LS Type: AS External Link
  Link State ID: 50.0.1.0 (External Network Number )
  Advertising Router: 0.1.0.1
  LS Seq Number: 80000001
  Checksum: 0x9556
  Length: 48
  Network Mask: /24
        Metric Type: 1 (Comparable directly to link state metric)
        TOS: 0 
        Metric: 0 
        Forward Address: 0.0.0.0
        External Route Tag: 0
        Metric Type: 1 (Comparable directly to link state metric)
        TOS: 10 
        Metric: 20 
        Forward Address: 0.0.0.0
        External Route Tag: 10

  Routing Bit Set on this LSA
  LS age: 19
  Options: (No TOS-capability, No DC)
  LS Type: AS External Link
  Link State ID: 50.0.2.0 (External Network Number )
  Advertising Router: 0.1.0.1
  LS Seq Number: 80000001
  Checksum: 0x8A60
  Length: 48
  Network Mask: /24
        Metric Type: 1 (Comparable directly to link state metric)
        TOS: 0 
        Metric: 0 
        Forward Address: 0.0.0.0
        External Route Tag: 0
        Metric Type: 1 (Comparable directly to link state metric)
        TOS: 10 
        Metric: 20 
        Forward Address: 0.0.0.0
        External Route Tag: 10





00000005
0a000000
01010101
80000001
b40b0024

ffffff00
80000001
01020300
000000ff

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|            LS age             |     Options   |      5        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Link State ID                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Advertising Router                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     LS sequence number                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         LS checksum           |             length            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Network Mask                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|E|     0       |                  metric                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Forwarding address                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      External Route Tag                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|E|    TOS      |                TOS  metric                    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Forwarding address                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      External Route Tag                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
