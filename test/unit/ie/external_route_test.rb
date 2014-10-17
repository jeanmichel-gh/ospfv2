require "test/unit"

require "ie/external_route"

class TestIeExternalRoute < Test::Unit::TestCase
  
  include OSPFv2
  def tests
    assert ExternalRoute.new
    assert_equal '0000000a0000000000000000', ExternalRoute.new( :metric=> 10).to_shex
    assert_equal '0000000a0000000000000000', ExternalRoute.new( :type=> :e1, :metric=> 10).to_shex
    assert_equal '8000000a0000000000000000', ExternalRoute.new( :type=> :e2, :metric=> 10).to_shex
    assert_equal '800000ff0101010100000000', ExternalRoute.new( :type=> :e2, 
                                                                :metric=> 255, 
                                                                :forwarding_address => '1.1.1.1').to_shex
    assert_equal '800000ff01010101000000ff', ExternalRoute.new( :type=> :e2, 
                                                                :metric=> 255, 
                                                                :forwarding_address => '1.1.1.1', 
                                                                :tag=> 255).to_shex
    assert_equal({:metric=>255, :type=>:e2, :forwarding_address=>"1.1.1.1", :tag=>255}, 
    h = ExternalRoute.new( :type=> :e2, :metric=> 255, :forwarding_address => '1.1.1.1', :tag=> 255).to_hash )
    assert_equal h, ExternalRoute.new(h).to_hash
    assert_equal h, ExternalRoute.new(ExternalRoute.new(h).encode).to_hash
    
    ext = ExternalRoute.new(h)
    assert_equal '800000ff01010101000000ff', ext.to_shex
    ext2 = ExternalRoute.new(ext)
    assert_equal '800000ff01010101000000ff', ext2.to_shex
    
    ext = ExternalRoute.new(['800000ff01010101000000ff'].pack('H*'))
    assert_equal 255, ext.tag
    assert_equal :e2, ext.type
    assert_equal '1.1.1.1', ext.forwarding_address.to_ip
    assert_equal 0, ext.mt_id
  end
  
  def test_mt
    assert_raise(ArgumentError) { MtExternalRoute.new }
    assert_raise(ArgumentError) { MtExternalRoute.new(:metric=> 10) }
    assert_raise(ArgumentError) { MtExternalRoute.new(:id=> 0) }
    assert MtExternalRoute.new(:mt_id=>1)
    ext = ExternalRoute.new(['810000ff01010101000000ff'].pack('H*'))
    assert_equal 255, ext.tag
    assert_equal :e2, ext.type
    assert_equal '1.1.1.1', ext.forwarding_address.to_ip
    assert_equal 1, ext.mt_id
    ext  =  MtExternalRoute.new(MtExternalRoute.new(:mt_id=>10, :tag=>20, :forwarding_address=>'1.1.1.1'))
    assert_equal ext.to_shex, MtExternalRoute.new(ext).to_shex
  end

end