require "test/unit"
require 'lsa/router'
require 'lsa/summary'
require 'lsa/network'

require "packet/link_state_ack"
require 'packet/link_state_update'


class TestPacketLinkStateAck < Test::Unit::TestCase
  include OSPFv2
  def setup
     @r = Router.new
     @n = Network.new
     @a = AsbrSummary.new
     @s = Summary.new
     @e = AsExternal.new
  end
  def tests
    assert LinkStateAck.new
    assert_equal '020500180000000000000000fde200000000000000000000', LinkStateAck.new.to_shex
    
    ls_ack = LinkStateAck.new
    ls_ack.lsa_headers << @r
    ls_ack.lsa_headers << @n
    ls_ack.lsa_headers << @s
    ls_ack.lsa_headers << @a
    ls_ack.lsa_headers << @e
  
  # 0205007c00000000000000001c6000000000000000000000
  # 0000000100000000000000008000000195d30014
  # 0000000200000000000000008000000187e00014
  # 0000000300000000000000008000000179ed0014
  # 000000040000000000000000800000016bfa0014
  # 000000050000000000000000800000015d080014
  # 
  # 0205007c0000000000000000cbb000000000000000000000
  # 000000010000000000000000800000019dc70018
  # 000000020000000000000000800000018fd40018
  # 0000000300000000000000008000000189d5001c
  # 000000040000000000000000800000017be2001c
  # 000000050000000000000000800000017dd70024
  
  end

  def test1
    s = "020500e0010101010000000086690000000000000000000000a122010101010101010101800000020000000000a122010101010201010102800000040000000000a122010202020202020202800000020000000000a722010aff08020aff08028000001a00000000009f000218000002010101028000000100000000009f000319000100010101028000000100000000009f000319000200010101028000000100000000009f000319000300010101028000000100000000009f000319000400010101028000000100000000009f000319000500010101028000000100000000".split.join
    ls_ack = LinkStateAck.new([s].pack('H*'))
    assert_equal 10, ls_ack.lsa_headers.size
    # p $style
    # $style=:junos_verbose
    # puts ls_ack
  end
  def test_2
    s = '0204006cc0a801c8000000004115000000000000000000000000000200012201c0a801c8c0a801c8800001a7b626003000000002c7000000ffffff0003000001c0a801c8c0a801c80200000a00012202c0a801c8c0a801c880000001e0bb0020ffffff00c0a801c801010101'
    ls_update = LinkStateUpdate.new([s].pack('H*'))
    #puts ls_update
    ls_ack = LinkStateAck.ack_ls_update ls_update, :area_id=> '1.2.3.4', :router_id=>'5.6.7.8'
    #puts ls_ack
    assert_equal 'link_state_ack', ls_ack.packet_name
    
    # puts ls_update.to_s_junos
  end
end
