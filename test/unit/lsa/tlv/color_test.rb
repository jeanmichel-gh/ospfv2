#TODO find spec for this TLV and rename it ?
#  	  LSA #3
#  	  Advertising Router 10.255.245.46, seq 0x8000001e, age 8s, length 104
#  	    Area Local Opaque LSA (10), Opaque-Type Traffic Engineering LSA (1), Opaque-ID 5
#  	    Options: [External, Demand Circuit]
#  	    Link TLV (2), length: 100
#  	      Link Type subTLV (1), length: 1, Point-to-point (1)
#  	      Link ID subTLV (2), length: 4, 12.1.1.1 (0x0c010101)
#  	      Local Interface IP address subTLV (3), length: 4, 192.168.208.88
#  	      Remote Interface IP address subTLV (4), length: 4, 192.168.208.89
#  	      Traffic Engineering Metric subTLV (5), length: 4, Metric 1
#  	      Maximum Bandwidth subTLV (6), length: 4, 155.520 Mbps
#  	      Maximum Reservable Bandwidth subTLV (7), length: 4, 155.520 Mbps
#  	      Unreserved Bandwidth subTLV (8), length: 32
#  		TE-Class 0: 155.520 Mbps
#  		TE-Class 1: 155.520 Mbps
#  		TE-Class 2: 155.520 Mbps
#  		TE-Class 3: 155.520 Mbps
#  		TE-Class 4: 155.520 Mbps
#  		TE-Class 5: 155.520 Mbps
#  		TE-Class 6: 155.520 Mbps
#  		TE-Class 7: 155.520 Mbps
#  	      Administrative Group subTLV (9), length: 4, 0x00000000

require "test/unit"

require "lsa/tlv/color"

class TestLsaTlvColor < Test::Unit::TestCase
  include OSPFv2
  def test_new
    assert_equal("0009000400000000", Color_Tlv.new().to_shex)
    assert_equal("OSPFv2::Color_Tlv: 254", Color_Tlv.new({:color=>254}).to_s)
    assert_equal("00090004000000fe", Color_Tlv.new({:color=>254}).to_shex)
    assert_equal(255, Color_Tlv.new({:color=>255}).to_hash[:color])
    assert_equal("000900040000ffff", Color_Tlv.new(Color_Tlv.new({:color=>0xffff}).encode).to_shex)
  end
end

