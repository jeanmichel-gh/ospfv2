require "test/unit"

require "ie/sequence_number"

class TestIeSequenceNumber < Test::Unit::TestCase
  include OSPFv2
  def test1
    sn = SequenceNumber.new()
    sn_init = SequenceNumber.new(:init)
    sn_max= SequenceNumber.new(:max)
    sn_resv= SequenceNumber.new(:reserved)
    assert_equal("0x80000001",sn.to_s)
    assert_equal("0x80000001",sn_init.to_s)
    assert_equal("0x7fffffff",sn_max.to_s)
    assert_equal("0x80000000",sn_resv.to_s)
    assert_equal(-1,sn_init <=> sn_max)
    assert_equal(-1,sn_resv <=> sn_init)
    assert_equal(1,sn_max <=> sn_init)
    assert_equal(true,sn_init < sn_max)
    assert_equal(true,sn_resv  < sn_init)
    assert_equal(true,sn_max > sn_init)
    assert_equal("0x80000003",(sn_init + 2).to_s)
    assert_equal("0x80000001",(sn_init - 2).to_s)
    assert_equal("0x80000002",SequenceNumber.to_s(0x80000002))
    assert_equal("0x00000001",SequenceNumber.to_s(1))
  
    assert_equal('0x80000001', SequenceNumber.new(SequenceNumber.new).to_s)
    
    
  end
end