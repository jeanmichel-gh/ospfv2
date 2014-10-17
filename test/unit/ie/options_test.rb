#
#  Created by Jean-Michel Esnault.
#  Copyright (c) 2008. All rights reserved.
#

require 'test/unit'
require 'pp'
require 'ie/options'

class TestOptions < Test::Unit::TestCase # :nodoc:
  include OSPFv2
  def test_dc_bit
    assert_equal("Options:  0x20  [DC]", Options.new({:DC=>1}).to_s)
    assert_equal("Options:  0x20  [DC]", Options.new({:dc=>1}).to_s)
    assert_equal(32, Options.new({:DC=>true}).options)
    assert_equal(32, Options.new({:dc=>true}).options)
    assert_equal(true, Options.new({:dc=>true}).dc?)
    assert_equal(0, Options.new({:DC=>0}).options)
    assert_equal(0, Options.new({:dc=>0}).options)
    assert_equal(0, Options.new({:DC=>false}).options)
    assert_equal(0, Options.new({:dc=>false}).options)
    assert_equal(false, Options.new({:dc=>false}).dc?)
  end
  def test_l_bit
    assert_equal("Options:  0x10  [L]", Options.new({:L=>1}).to_s)
    assert_equal("Options:  0x10  [L]", Options.new({:l=>1}).to_s)
    assert_equal(16, Options.new({:L=>true}).options)
    assert_equal(16, Options.new({:l=>true}).options)
    assert_equal(true, Options.new({:l=>true}).l?)
    assert_equal(0, Options.new({:L=>0}).options)
    assert_equal(0, Options.new({:l=>0}).options)
    assert_equal(0, Options.new({:L=>false}).options)
    assert_equal(0, Options.new({:l=>false}).options)
    assert_equal(false, Options.new({:l=>false}).l?)
  end
  def test_n_bit
    assert_equal("Options:  0x8  [N]", Options.new({:N=>1}).to_s)
    assert_equal("Options:  0x8  [N]", Options.new({:n=>1}).to_s)
    assert_equal(8, Options.new({:N=>true}).options)
    assert_equal(8, Options.new({:n=>true}).options)
    assert_equal(true, Options.new({:n=>true}).n?)
    assert_equal(true, Options.new({:p=>true}).p?)
    assert_equal(0, Options.new({:N=>0}).options)
    assert_equal(0, Options.new({:n=>0}).options)
    assert_equal(0, Options.new({:N=>false}).options)
    assert_equal(0, Options.new({:n=>false}).options)
    assert_equal(false, Options.new({:n=>false}).n?)
  end
  def test_mc_bit
    assert_equal("Options:  0x4  [MC]", Options.new({:MC=>1}).to_s)
    assert_equal("Options:  0x4  [MC]", Options.new({:mc=>1}).to_s)
    assert_equal(4, Options.new({:MC=>true}).options)
    assert_equal(4, Options.new({:mc=>true}).options)
    assert_equal(true, Options.new({:mc=>true}).mc?)
    assert_equal(0, Options.new({:MC=>0}).options)
    assert_equal(0, Options.new({:mc=>0}).options)
    assert_equal(0, Options.new({:MC=>false}).options)
    assert_equal(0, Options.new({:mc=>false}).options)
    assert_equal(false, Options.new({:mc=>false}).mc?)
  end
  def test_e_bit
    assert_equal("Options:  0x2  [E]", Options.new({:E=>1}).to_s)
    assert_equal("Options:  0x2  [E]", Options.new({:e=>1}).to_s)
    assert_equal(2, Options.new({:E=>true}).options)
    assert_equal(2, Options.new({:e=>true}).options)
    assert_equal(true, Options.new({:e=>true}).e?)
    assert_equal(0, Options.new({:E=>0}).options)
    assert_equal(0, Options.new({:e=>0}).options)
    assert_equal(0, Options.new({:E=>false}).options)
    assert_equal(0, Options.new({:e=>false}).options)
    assert_equal(false, Options.new({:e=>false}).e?)
  end
  def test_v6_bit
    assert_equal("Options:  0x1  [V6]", Options.new({:V6=>1}).to_s)
    assert_equal("Options:  0x1  [V6]", Options.new({:v6=>1}).to_s)
    assert_equal(1, Options.new({:V6=>true}).options)
    assert_equal(1, Options.new({:v6=>true}).options)
    assert_equal(true, Options.new({:v6=>true}).v6?)
    assert_equal(0, Options.new({:V6=>0}).options)
    assert_equal(0, Options.new({:v6=>0}).options)
    assert_equal(0, Options.new({:V6=>false}).options)
    assert_equal(0, Options.new({:v6=>false}).options)
    assert_equal(false, Options.new({:v6=>false}).v6?)
  end
  def test_opaque_bit
    assert_equal("Options:  0x40  [O]", Options.new({:O=>1}).to_s)
    assert_equal("Options:  0x40  [O]", Options.new({:o=>1}).to_s)
    assert_equal(64, Options.new({:O=>true}).options)
    assert_equal(64, Options.new({:o=>true}).options)
    assert_equal(true, Options.new({:o=>true}).o?)
    assert_equal(0, Options.new({:O=>0}).options)
    assert_equal(0, Options.new({:o=>0}).options)
    assert_equal(0, Options.new({:o=>false}).options)
    assert_equal(0, Options.new({:o=>false}).options)
    assert_equal(false, Options.new({:o=>false}).o?)
  end
  def test_set_multi_bit
    opt = Options.new
    opt.setDC 
    assert_equal("Options:  0x20  [DC]", opt.to_s)
    opt.setL
    assert_equal("Options:  0x30  [L,DC]", opt.to_s)
    opt.setN
    assert_equal("Options:  0x38  [L,DC,N]", opt.to_s)
    opt.setMC
    assert_equal("Options:  0x3c  [L,DC,N,MC]", opt.to_s)
    opt.setE
    assert_equal("Options:  0x3e  [L,DC,N,MC,E]", opt.to_s)
    opt.setV6
    assert_equal("Options:  0x3f  [L,DC,N,MC,E,V6]", opt.to_s)
    opt = Options.new
    opt.setDC << opt.setV6 << opt.setMC
    assert_equal("Options:  0x25  [DC,MC,V6]", opt.to_s)
  end
  def test_unset_multi_bit
    opt = Options.new
    opt.options=0x7f
    assert_equal("Options:  0x7f  [O,L,DC,N,MC,E,V6]", opt.to_s)
    opt.unsetE << opt.unsetMC
    assert_equal("Options:  0x79  [O,L,DC,N,V6]", opt.to_s)
    opt.unsetDC << opt.unsetL << opt.unsetO
    assert_equal("Options:  0x9  [N,V6]", opt.to_s)
    opt.unsetV6 << opt.unsetN
    assert_equal(0, opt.options)
  end
  def test_set_nssa
    opt = Options.new
    opt.setE 
    assert_equal("Options:  0x2  [E]", opt.to_s)
    opt.setNSSA 
    assert_equal("Options:  0x8  [N]", opt.to_s)
  end

  def test_enc
    opt = Options.new([0x3f].pack('C'))
    assert_equal("Options:  0x3f  [L,DC,N,MC,E,V6]", opt.to_s)
    assert_equal(true, opt.dc?)
    assert_equal(true, opt.e?)
    assert_equal("3f", opt.to_shex)
  end

end
