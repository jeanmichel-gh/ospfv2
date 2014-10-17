require "test/unit"
require "lsa/summary"

class TestLsaSummary < Test::Unit::TestCase
  include OSPFv2
  
  def setup
    Summary.reset
  end
  
  def test_new
    h = {
      :advertising_router=>"1.1.1.1",
      :ls_id=>"10.0.0.0",
      :metric =>1,
      :netmask => "255.255.255.0"
    }
    summary = Summary.new h
    assert_equal "000000030a0000000101010180000001f25d001cffffff0000000001", summary.to_shex
  end
  
  def test_mt_metric
    h = {
      :advertising_router=>"1.1.1.1",
      :ls_id=>"10.0.0.0",
      :metric => 1,
      :netmask => "255.255.255.0",
      :mt_metrics => [{:id=>33, :metric=>20}, {:id=>34, :metric=>255}]
    }
    summary = Summary.new h
    assert_equal("000000030a000000010101018000000188680024ffffff000000000121000014220000ff",summary.to_shex)
    assert_equal summary.to_shex, Summary.new(summary.to_hash).to_shex
    assert_equal summary.to_shex, Summary.new(summary).to_shex
    h = summary.to_hash
    assert_equal 0, h[:ls_age]
    assert_equal '1.1.1.1', h[:advertising_router]
    assert_equal '10.0.0.0', h[:ls_id]
    assert_equal :summary, h[:ls_type]
    assert_equal 0x80000001, h[:sequence_number]
    assert_equal '255.255.255.0', h[:netmask]
    assert_equal 0, h[:options]
    assert_equal 33, h[:mt_metrics][0][:id]
    assert_equal 20, h[:mt_metrics][0][:metric]
    assert_equal 1, h[:metric]
    s = Summary.new_ntop(summary.encode)
    assert_equal summary.to_shex, s.to_shex
    assert_match /Topology \(ID 33\) -> Metric: 20/, summary.to_s_junos_verbose
    assert_match /Topology \(ID 34\) -> Metric: 255/, summary.to_s_junos_verbose
    end
    
    def test_fix_hash
      h1 = {
        :advertising_router=>"1.1.1.1",
        :ls_id=>"10.0.0.0",
        :metric => 1,
        :netmask => "255.255.255.0",
        :mt_metrics => [{:id=>33, :metric=>20}, {:id=>34, :metric=>255}]
      }
      summary1 = Summary.new h1
      h2 = {
        :advertising_router=>"1.1.1.1",
        :network=>"10.0.0.0/24",
        :metric => 1,
        :mt_metrics => [{:id=>33, :metric=>20}, {:id=>34, :metric=>255}]
      }
      summary2 = Summary.new h2
      assert_equal(summary2.encode, summary1.encode)
      assert summary1.summary?

      # puts summary1.to_s_ios
      # puts summary1.to_s_ios_verbose
      
    end
    
    def test_count
      Summary.new_lsdb
      assert_equal "30.0.0.#{Summary.count}/24", Summary.network
      Summary.new_lsdb
      assert_equal 2, Summary.count
      assert_equal "30.0.0.#{Summary.count}/24", Summary.network
      
    end
    
    def test_new_lsdb
      #FIXME: finish the work: what was the intent?
      # puts Summary.new_lsdb :advertising_router=> 1, :metric => (Summary.count) +1
      # puts Summary.new_lsdb :advertising_router=> 1, :metric => (Summary.count) +1
    end
    
end


class TestLsaAsbrSummary < Test::Unit::TestCase
  include OSPFv2
  def test_asbr_new
    asbr_summary = AsbrSummary.new(:advertising_router=>"1.1.1.1", :ls_id=>"1.1.1.1")
    assert_equal("000000040101010101010101800000012f27001c0000000000000000",asbr_summary.to_shex)
    assert_equal asbr_summary.to_shex, AsbrSummary.new(asbr_summary.to_hash).to_shex
    assert_equal asbr_summary.to_shex, AsbrSummary.new(asbr_summary).to_shex
  end
end


__END__

R1#show ip ospf database summary 

            OSPF Router with ID (1.1.1.1) (Process ID 1)

                Summary Net Link States (Area 0)

  Routing Bit Set on this LSA
  LS age: 67
  Options: (No TOS-capability, No DC, Upward)
  LS Type: Summary Links(Network)
  Link State ID: 30.0.1.0 (summary Network Number)
  Advertising Router: 0.1.0.1
  LS Seq Number: 80000001
  Checksum: 0xE855
  Length: 28
  Network Mask: /24
        TOS: 0  Metric: 0 

  Routing Bit Set on this LSA
  LS age: 67
  Options: (No TOS-capability, No DC, Upward)
  LS Type: Summary Links(Network)
  Link State ID: 30.0.2.0 (summary Network Number)
  Advertising Router: 0.1.0.1
  LS Seq Number: 80000001
  Checksum: 0xDD5F
  Length: 28
  Network Mask: /24
        TOS: 0  Metric: 0 

