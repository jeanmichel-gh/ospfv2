require 'test/unit'
require 'ospfv2'

# Fletcher checksum (RFC 2328 12.1.7): every LSA we encode must verify,
# including LSAs longer than MODX (4102 bytes), which the original loop
# silently truncated.
class TestLsaChecksum < Test::Unit::TestCase
  include OSPFv2

  def verify(lsa)
    bytes = lsa.encode
    lsa.send(:cheksum, bytes[2..], 0)
  end

  def test_small_lsas_verify
    [Router.new(advertising_router: 1, ls_id: 1),
     Summary.new(advertising_router: 1, network: '10.0.0.0/24', metric: 7),
     AsExternal.new(advertising_router: 1, network: '50.0.0.0/24', metric: 20, type: :e2, tag: 5),
     Network.new(advertising_router: 1, ls_id: '192.168.0.1', network_mask: '255.255.255.0', attached_routers: [1, 2])]
      .each { |l| assert_equal [0, 0], verify(l), l.class.to_s }
  end

  def test_large_router_lsa_over_modx_verifies
    r = Router.new(advertising_router: 1, ls_id: 1)
    400.times { |i| r << { router_link_type: :stub_network, link_id: IP.create(0x0a000000 + (i << 8)).to_s, link_data: '255.255.255.0', metric: 1 } }
    assert r.encode.bytesize > 4102
    assert_equal [0, 0], verify(r)
  end

  def test_checksum_changes_with_content
    a = Summary.new(advertising_router: 1, network: '10.0.0.0/24', metric: 7).encode
    b = Summary.new(advertising_router: 1, network: '10.0.0.0/24', metric: 8).encode
    assert_not_equal a[16, 2], b[16, 2]
  end

  def test_age_is_not_covered
    l = Summary.new(advertising_router: 1, network: '10.0.0.0/24')
    before = l.encode[16, 2]
    l.instance_variable_set(:@ls_age, LsAge.new(1234))
    assert_equal before, l.encode[16, 2]
  end

  def test_parse_warns_on_corrupt_lsa
    bytes = Summary.new(advertising_router: 1, network: '10.0.0.0/24').encode.dup
    bytes.setbyte(25, (bytes.getbyte(25) + 1) % 256) # not ^0xff: mod 255 cannot see 0x00 <-> 0xff
    _, err = capture_output { Summary.new(bytes) }
    assert_match(/checksum error/, err)
  end
end
