# frozen_string_literal: true

require 'test/unit'
require 'ospfv2'
require 'ospfv2/core'

# Addresses, LSAs and packets. The old codec classes serve as a second,
# independent implementation: both must agree byte for byte.
class TestCoreAddr < Test::Unit::TestCase
  include OSPFv2::Core

  def test_round_trip
    assert_equal 0x0a000001, Addr.to_i('10.0.0.1')
    assert_equal '10.0.0.1', Addr.to_s(0x0a000001)
    assert_equal 7, Addr.to_i(7)
  end

  def test_masks
    assert_equal 0xffffff00, Addr.mask(24)
    assert_equal 0, Addr.mask(0)
    assert_equal 0xffffffff, Addr.mask(32)
    assert_equal 24, Addr.prefix_len(0xffffff00)
    assert_raise(ArgumentError) { Addr.prefix_len(0xff00ff00) }
  end

  def test_parse_prefix
    assert_equal [Addr.to_i('10.1.2.3'), 30], Addr.parse_prefix('10.1.2.3/30')
    ['10.1.2.3', '10.1.2.3/33', '10.1.2/24', 'x/24', '10.1.2.3/ 4'].each do |bad|
      assert_raise(ArgumentError, bad) { Addr.parse_prefix(bad) }
    end
  end

  def test_rejects_garbage
    assert_raise(ArgumentError) { Addr.to_i('1.2.3') }
    assert_raise(ArgumentError) { Addr.to_i('300.1.1.1') }
    assert_raise(ArgumentError) { Addr.to_i(-1) }
    assert_raise(ArgumentError) { Addr.to_i(nil) }
  end
end

class TestCoreLsa < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  def router_lsa(seq: Lsa::INITIAL_SEQ, age: 0, metric: 10)
    Lsa.router(advr: '1.1.1.1', seq: seq, age: age,
               links: [{ type: 3, id: '10.0.0.0', data: '255.255.255.0', metric: metric },
                       { type: 1, id: '2.2.2.2', data: '10.0.12.1', metric: 1 }])
  end

  def test_router_lsa_matches_the_old_codec
    lsa = router_lsa
    assert lsa.checksum_ok?
    old = OSPFv2::Router.new_ntop(lsa.bytes)
    assert_equal lsa.bytes, old.encode
    assert_equal 2, old.links.size
  end

  def test_network_lsa_matches_the_old_codec
    lsa = Lsa.network(dr_address: '10.0.0.1', advr: '1.1.1.1', mask: '255.255.255.0',
                      attached: %w[1.1.1.1 2.2.2.2 3.3.3.3], seq: Lsa::INITIAL_SEQ + 5)
    assert lsa.checksum_ok?
    assert_equal lsa.bytes, OSPFv2::Network.new_ntop(lsa.bytes).encode
    mask, routers = lsa.network_body
    assert_equal '255.255.255.0', Addr.to_s(mask)
    assert_equal %w[1.1.1.1 2.2.2.2 3.3.3.3], routers.map { |r| Addr.to_s(r) }
  end

  def test_fletcher_agrees_with_the_old_code_on_large_lsas
    # The old code had a bug past 4102 bytes; this is the regression check.
    links = Array.new(400) { |i| { type: 3, id: (10 << 24) + (i << 8), data: 0xffffff00, metric: i } }
    lsa = Lsa.router(advr: '9.9.9.9', seq: 1, links: links)
    assert_operator lsa.length, :>, 4102
    assert lsa.checksum_ok?
    assert_equal lsa.bytes, OSPFv2::Router.new_ntop(lsa.bytes).encode
  end

  def test_corruption_is_detected
    raw = router_lsa.bytes.dup
    raw[30] = (raw.getbyte(30) ^ 0x40).chr
    assert !Lsa.new(raw).checksum_ok?
  end

  def test_age_is_outside_the_checksum
    lsa = router_lsa.with_age(1234)
    assert_equal 1234, lsa.age
    assert lsa.checksum_ok?
    assert_equal OSPFv2::MaxAge, lsa.with_age(99_999).age
  end

  def test_router_links
    flags, links = router_lsa.router_body
    assert_equal 0, flags
    assert_equal %i[stub p2p], links.map(&:type_name)
    assert_equal '2.2.2.2', Addr.to_s(links[1].id)
    assert_equal 1, links[1].metric
  end

  def test_signed_sequence_numbers
    assert_equal(-0x7fff_ffff, router_lsa.seq)
    assert_equal '0x80000001', format('0x%08x', router_lsa.seq & 0xffff_ffff)
    assert router_lsa(seq: 0).newer_than?(router_lsa(seq: -1))
    assert router_lsa(seq: Lsa::MAX_SEQ).newer_than?(router_lsa(seq: Lsa::INITIAL_SEQ))
  end

  # RFC 2328 13.1, rule by rule.
  def test_which_instance_is_newer
    a = router_lsa(seq: 5)
    assert a.newer_than?(router_lsa(seq: 4)), 'higher sequence'
    b = router_lsa(seq: 5, metric: 11)
    hi, lo = [a, b].sort_by(&:checksum).reverse
    assert hi.newer_than?(lo), 'same sequence, higher checksum'
    old = a.with_age(OSPFv2::MaxAge)
    assert old.newer_than?(a.with_age(100)), 'MaxAge wins'
    assert a.with_age(10).newer_than?(a.with_age(10 + OSPFv2::MaxAgeDiff + 1)), 'much younger wins'
    assert a.with_age(10).same_instance?(a.with_age(10 + OSPFv2::MaxAgeDiff)), 'ages within MaxAgeDiff are the same'
  end

  def test_header_compares_like_the_lsa
    a = router_lsa(seq: 7)
    h = a.header
    assert_equal a.key, h.key
    assert h.same_instance?(a)
    assert a.newer_than?(router_lsa(seq: 6).header)
    assert_equal a.encode_header, h.encode
  end

  def test_parse_rejects_bad_lengths
    raw = router_lsa.bytes
    assert_raise(Lsa::Error) { Lsa.parse(raw.byteslice(0, 10)) }
    assert_raise(Lsa::Error) { Lsa.parse(raw.byteslice(0, raw.bytesize - 1)) }
    bad = raw.dup
    bad[18, 2] = [8].pack('n')
    assert_raise(Lsa::Error) { Lsa.parse(bad) }
  end
end

class TestCoreWire < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  RID = Addr.to_i('1.1.1.1')
  AREA = Addr.to_i('0.0.0.1')

  def round_trip(body)
    bytes = Wire.encode(body, router_id: RID, area_id: AREA)
    pkt = Wire.decode(bytes)
    assert_equal RID, pkt.router_id
    assert_equal AREA, pkt.area_id
    assert_equal body.class, pkt.body.class
    [bytes, pkt.body]
  end

  def lsa(i)
    Lsa.router(advr: i, seq: Lsa::INITIAL_SEQ + i, links: [{ type: 3, id: i << 8, data: 0xffffff00, metric: i }])
  end

  def test_hello
    h = Wire::Hello.new(netmask: 0xffffff00, hello_interval: 10, options: 2, priority: 1, dead_interval: 40,
                        dr: Addr.to_i('10.0.0.2'), bdr: Addr.to_i('10.0.0.1'), neighbors: [7, 8])
    bytes, got = round_trip(h)
    assert_equal h, got
    old = OSPFv2::Hello.new(bytes)
    assert_equal ['0.0.0.7', '0.0.0.8'], old.neighbors.to_s_ary
    assert_equal '10.0.0.2', old.designated_router_id.to_ip
    assert_equal bytes, old.encode
  end

  def test_database_description
    dd = Wire::DatabaseDescription.new(mtu: 1500, options: 0x42, flags: Wire::DD_MORE | Wire::DD_MASTER,
                                       seq: 0xdeadbeef, headers: [lsa(1), lsa(2)].map(&:header))
    bytes, got = round_trip(dd)
    assert_equal dd.headers, got.headers
    assert got.more? && got.master? && !got.init?
    assert_equal 'M|MS', got.flag_string
    assert_equal 0x42, got.options

    # The old DD parser drops the options byte, so it re-encodes 0 there
    # and the checksum differs. Everything else must match.
    old = OSPFv2::DatabaseDescription.new(bytes)
    assert_equal 0xdeadbeef, old.dd_sequence_number.to_i
    mask = ->(b) { b.dup.tap { |x| x[12, 2] = "\0\0"; x[26] = "\0" } }
    assert_equal mask.(bytes), mask.(old.encode)
  end

  def test_ls_request
    req = Wire::LinkStateRequest.new(requests: [[1, 5, 5], [2, 0x0a000001, 9]])
    bytes, got = round_trip(req)
    assert_equal req.requests, got.requests
    assert_equal 2, OSPFv2::LinkStateRequest.new(bytes).requests.size
  end

  def test_ls_update_keeps_lsas_byte_exact
    lsas = [lsa(1), lsa(2).with_age(300), lsa(3)]
    bytes, got = round_trip(Wire::LinkStateUpdate.new(lsas: lsas))
    assert_equal lsas.map(&:bytes), got.lsas.map(&:bytes)
    assert_equal 3, OSPFv2::LinkStateUpdate.new(bytes).number_of_lsa
  end

  def test_ls_ack
    ack = Wire::LinkStateAck.new(headers: [lsa(4).header, lsa(5).header])
    bytes, got = round_trip(ack)
    assert_equal ack.headers, got.headers
    assert_equal bytes, OSPFv2::LinkStateAck.new(bytes).encode
  end

  def test_decodes_packets_built_by_the_old_codec
    old = OSPFv2::Hello.new(router_id: '3.3.3.3', area_id: 0, netmask: '255.255.255.0', hello_interval: 10,
                            router_dead_interval: 40, rtr_pri: 0, options: 2,
                            designated_router_id: '0.0.0.0', backup_designated_router_id: '0.0.0.0')
    pkt = Wire.decode(old.encode)
    assert_equal Addr.to_i('3.3.3.3'), pkt.router_id
    assert_equal 0, pkt.body.priority
  end

  def test_trailing_lls_block_is_ignored
    bytes = Wire.encode(Wire::Hello.new(netmask: 0, hello_interval: 10, options: 0x12, priority: 1,
                                        dead_interval: 40, dr: 0, bdr: 0, neighbors: []),
                        router_id: RID, area_id: 0)
    pkt = Wire.decode(bytes + "\xff\xf6\x00\x03\x00\x01\x00\x04\x00\x00\x00\x01".b)
    assert_equal 10, pkt.body.hello_interval
  end

  def test_rejects_malformed_packets
    good = Wire.encode(Wire::LinkStateAck.new(headers: [lsa(1).header]), router_id: RID, area_id: 0)
    cases = {
      'too short' => good.byteslice(0, 20),
      'version' => good.dup.tap { |b| b.setbyte(0, 3) },
      'checksum' => good.dup.tap { |b| b.setbyte(30, b.getbyte(30) ^ 1) },
      'type' => good.dup.tap { |b| b.setbyte(1, 9) },
      'length' => good.dup.tap { |b| b[2, 2] = [9999].pack('n') },
      'auth' => good.dup.tap { |b| b[14, 2] = [1].pack('n') }
    }
    cases.each do |name, bytes|
      assert_raise(Wire::Error, name) { Wire.decode(bytes) }
    end
  end

  def test_rejects_a_truncated_lsa_inside_an_update
    body = Wire::LinkStateUpdate.new(lsas: [lsa(1)])
    raw = Wire.encode(body, router_id: RID, area_id: 0)
    raw[24, 4] = [2].pack('N') # claims two LSAs
    raw[12, 2] = "\0\0"
    raw[12, 2] = [Wire.inet_checksum(raw)].pack('n')
    assert_raise(Wire::Error) { Wire.decode(raw) }
  end

  def test_batches_respect_the_room
    sizes = [400, 400, 400, 900, 100]
    out = Wire.batches(sizes, 1000, fixed: 4) { |s| s }
    assert_equal [[400, 400], [400], [900], [100]], out
    assert_equal [[2000]], Wire.batches([2000], 1000) { |s| s }
  end
end
