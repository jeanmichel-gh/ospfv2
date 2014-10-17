require "test/unit"

require "lsa/network"

class TestLasNetwork < Test::Unit::TestCase
  include OSPFv2
  def setup
    $style = :default
  end
  def tests
    assert Network.new
    assert_equal '000000020000000000000000800000018fd4001800000000', Network.new.to_shex
    assert_equal '000000020000000000000000800000018fd40018ffffff00', Network.new(:network_mask => '255.255.255.0').to_shex
    net =  Network.new :network_mask => '255.255.255.0', :ls_id=>'192.168.0.1', :advertising_router => '1.1.1.1'
    to_s_headerhex = net.to_shex
    assert_equal 4*5,net.encode_header.size
    net << '1.1.1.1'
    net << '2.2.2.2'
    net << '3.3.3.3'
    assert_equal 3, net.attached_routers.size
    assert_equal '00000002c0a8000101010101800000011bb60024ffffff00010101010202020203030303', net.to_shex    
    net1 = Network.new_ntop ['00000002c0a8000101010101800000011bb60024ffffff00010101010202020203030303'].pack('H*')
    assert_equal net.to_shex, net1.to_shex
    assert_equal net.to_shex, Network.new(net1.to_hash).to_shex
  end
  def test_hash
  end
  def test_to_s
    net =  Network.new :network_mask => '255.255.255.0', :ls_id=>'192.168.0.1', :advertising_router => '1.1.1.1'
    net << '1.1.1.1'
    net << '2.2.2.2'
    net << '3.3.3.3'
    assert_match(/NetworkMask: 255.255.255.0/, net.to_s_verbose)
    assert_match(/AttachRouter: 1.1.1.1/, net.to_s_verbose)
    assert_match(/AttachRouter: 2.2.2.2/, net.to_s_verbose)
    assert_match(/AttachRouter: 3.3.3.3/, net.to_s_verbose)
  end
  def test_to_s_junos
    $style = :junos
    net =  Network.new :network_mask => '255.255.255.0', :ls_id=>'192.168.0.1', :advertising_router => '1.1.1.1'
    net << '1.1.1.1'
    net << '2.2.2.2'
    net << '3.3.3.3'
    
    assert_no_match  /\s\smask 255.255.255.0/, net.to_s
    assert_no_match  /\s\sattached router 1.1.1.1/, net.to_s
    assert_no_match  /\s\sattached router 3.3.3.3/, net.to_s
    assert_match  /\s\smask 255.255.255.0/, net.to_s_junos_verbose
    assert_match  /\s\sattached router 1.1.1.1/, net.to_s_junos_verbose
    assert_match  /\s\sattached router 3.3.3.3/, net.to_s_junos_verbose
    assert_equal 'Network  192.168.0.1      1.1.1.1          0x80000001     0  0x00 0x1bb6  36', net.to_s_junos
  end
  
  def test_to_s_ios
    net =  Network.new :network_mask => '255.255.255.0', :ls_id=>'192.168.0.1', :advertising_router => '1.1.1.1'
    net << '1.1.1.1'
    net << '2.2.2.2'
    net << '3.3.3.3'
    
    # puts net.to_s_ios
    # puts net.to_s_ios_verbose
  end
  
  
end

__END__


R1#show ip ospf database network 

            OSPF Router with ID (1.1.1.1) (Process ID 1)

                Net Link States (Area 0)

  Routing Bit Set on this LSA
  LS age: 612
  Options: (No TOS-capability, DC)
  LS Type: Network Links
  Link State ID: 192.168.0.2 (address of Designated Router)
  Advertising Router: 2.2.2.2
  LS Seq Number: 80000015
  Checksum: 0xEBBA
  Length: 32
  Network Mask: /24
        Attached Router: 2.2.2.2
        Attached Router: 1.1.1.1

R1#




                 Net Link States (Area 0)
 
 LS age: 806
 Options:  0x22  [DC,E]
 LS Type: Network Links
 Link State ID: 192.168.0.2 
 Advertising Router: 2.2.2.2
 LS Seq Number: 80000015
 Checksum: 0xEBBA
 Length: 32
 Network Mask: 255.255.255.0
       Attached Router 2.2.2.2
       Attached Router 1.1.1.1
 
