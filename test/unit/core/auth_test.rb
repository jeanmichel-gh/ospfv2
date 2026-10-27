# frozen_string_literal: true

require 'test/unit'
require 'digest/md5'
require 'openssl'
require 'support/core_lab'

# Packet authentication: null, simple, keyed MD5 (RFC 2328 D) and
# HMAC-SHA (RFC 5709). Digests are checked against independent
# computations, not against the code under test.
class TestCoreAuth < Test::Unit::TestCase
  include OSPFv2
  include OSPFv2::Core

  RID = Addr.to_i('1.1.1.1')
  HELLO = Wire::Hello.new(netmask: 0xffffff00, hello_interval: 10, options: 2, priority: 1,
                          dead_interval: 40, dr: 0, bdr: 0, neighbors: [Addr.to_i('2.2.2.2')])

  def crypto(type, keys, clock: -> { 1_000 }, **opts)
    Auth.build({ type: type, keys: keys, **opts }, clock: clock)
  end

  def encode(auth, body = HELLO)
    Wire.encode(body, router_id: RID, area_id: 0, auth: auth)
  end

  # The OSPF packet alone, without the trailer, as the digest covers it.
  def packet_part(bytes)
    bytes.byteslice(0, bytes.byteslice(2, 2).unpack1('n'))
  end

  # ---- codec ----

  def test_null_is_the_default_and_round_trips
    bytes = encode(Auth.build(nil))
    assert_equal 0, bytes.byteslice(14, 2).unpack1('n')
    pkt = Wire.decode(bytes)
    assert_equal HELLO, pkt.body
    assert_nil pkt.key_id
    assert_nil pkt.crypto_seq
  end

  def test_simple_password
    auth = Auth.build(type: :simple, password: 'ospf')
    bytes = encode(auth)
    assert_equal 1, bytes.byteslice(14, 2).unpack1('n')
    assert_equal "ospf\0\0\0\0".b, bytes.byteslice(16, 8)
    assert_equal 0, Wire.inet_checksum(bytes), 'checksum still computed, auth field excluded'
    assert_equal HELLO, Wire.decode(bytes, auth: auth).body

    e = assert_raise(Wire::AuthError) { Wire.decode(bytes, auth: Auth.build(type: :simple, password: 'other')) }
    assert_match(/wrong password/, e.message)
    corrupt = bytes.dup.tap { |b| b.setbyte(30, b.getbyte(30) ^ 1) }
    assert_raise(Wire::Error) { Wire.decode(corrupt, auth: auth) }
  end

  def test_md5_matches_rfc2328_appendix_d
    auth = crypto(:md5, { 7 => 'secret' })
    bytes = encode(auth)
    pkt = packet_part(bytes)
    assert_equal 2, pkt.byteslice(14, 2).unpack1('n')
    assert_equal 0, pkt.byteslice(12, 2).unpack1('n'), 'no checksum with cryptographic authentication'
    zero, key_id, dlen, seq = pkt.byteslice(16, 8).unpack('nCCN')
    assert_equal [0, 7, 16, 1_000], [zero, key_id, dlen, seq]
    assert_equal pkt.bytesize + 16, bytes.bytesize, 'digest follows the packet, outside its length'

    expected = Digest::MD5.digest(pkt + "secret#{"\0" * 10}")
    assert_equal expected, bytes.byteslice(pkt.bytesize, 16)

    got = Wire.decode(bytes, auth: auth)
    assert_equal [7, 1_000], [got.key_id, got.crypto_seq]
    assert_equal HELLO, got.body
  end

  def test_hmac_sha_matches_rfc5709
    { hmac_sha1: ['SHA1', 20], hmac_sha256: ['SHA256', 32],
      hmac_sha384: ['SHA384', 48], hmac_sha512: ['SHA512', 64] }.each do |type, (digest, len)|
      auth = crypto(type, { 1 => 'short key' })
      bytes = encode(auth)
      pkt = packet_part(bytes)
      assert_equal len, pkt.getbyte(19), "#{type} auth data length"
      apad = ([0x878F_E1F3].pack('N') * (len / 4))
      expected = OpenSSL::HMAC.digest(digest, 'short key', pkt + apad)
      assert_equal expected, bytes.byteslice(pkt.bytesize, len), type.to_s
      assert_equal HELLO, Wire.decode(bytes, auth: auth).body
    end
  end

  def test_hmac_key_longer_than_the_hash_is_hashed_first
    # 40 bytes: longer than SHA-256 output (32) but shorter than its block
    # (64). RFC 5709 hashes it; plain HMAC would not.
    secret = 'k' * 40
    bytes = encode(crypto(:hmac_sha256, { 1 => secret }))
    pkt = packet_part(bytes)
    apad = [0x878F_E1F3].pack('N') * 8
    rfc5709 = OpenSSL::HMAC.digest('SHA256', OpenSSL::Digest.digest('SHA256', secret), pkt + apad)
    plain = OpenSSL::HMAC.digest('SHA256', secret, pkt + apad)
    assert_equal rfc5709, bytes.byteslice(pkt.bytesize, 32)
    assert_not_equal plain, rfc5709
  end

  def test_tampering_is_caught
    auth = crypto(:hmac_sha256, { 1 => 'k' })
    good = encode(auth)
    plen = packet_part(good).bytesize
    {
      'body' => good.dup.tap { |b| b.setbyte(30, b.getbyte(30) ^ 1) },
      'router id' => good.dup.tap { |b| b.setbyte(7, 9) },
      'sequence' => good.dup.tap { |b| b.setbyte(23, b.getbyte(23) ^ 1) },
      'digest' => good.dup.tap { |b| b.setbyte(plen + 5, b.getbyte(plen + 5) ^ 1) }
    }.each do |what, bytes|
      e = assert_raise(Wire::AuthError, what) { Wire.decode(bytes, auth: auth) }
      assert_match(/digest mismatch/, e.message, what)
    end

    e = assert_raise(Wire::AuthError) { Wire.decode(good.byteslice(0, plen + 10), auth: auth) }
    assert_match(/missing authentication data/, e.message)
    e = assert_raise(Wire::AuthError) { Wire.decode(good, auth: crypto(:hmac_sha256, { 2 => 'k' })) }
    assert_match(/unknown key id 1/, e.message)
    e = assert_raise(Wire::AuthError) { Wire.decode(good, auth: crypto(:hmac_sha1, { 1 => 'k' })) }
    assert_match(/length 32, expected 20/, e.message)
    e = assert_raise(Wire::AuthError) { Wire.decode(good, auth: crypto(:hmac_sha256, { 1 => 'other' })) }
    assert_match(/digest mismatch/, e.message)
  end

  def test_autype_must_match
    md5 = encode(crypto(:md5, { 1 => 'k' }))
    e = assert_raise(Wire::AuthError) { Wire.decode(md5) }
    assert_match(/type 2 \(cryptographic\), expected 0 \(null\)/, e.message)
    assert_raise(Wire::AuthError) { Wire.decode(encode(Auth.build(nil)), auth: crypto(:md5, { 1 => 'k' })) }
  end

  def test_trailing_lls_block_after_the_digest_is_ignored
    auth = crypto(:md5, { 1 => 'k' })
    lls = "\xff\xf6\x00\x03\x00\x01\x00\x04\x00\x00\x00\x01".b
    assert_equal HELLO, Wire.decode(encode(auth) + lls, auth: auth).body
  end

  # ---- keys and sequence numbers ----

  def test_sends_with_the_highest_key_unless_told_and_accepts_every_key
    both = crypto(:md5, { 1 => 'old', 2 => 'new' })
    old_only = crypto(:md5, { 1 => 'old' })
    assert_equal 2, both.send_key.id
    assert_raise(Wire::AuthError) { Wire.decode(encode(both), auth: old_only) }
    assert_equal 1, Wire.decode(encode(old_only), auth: both).key_id
    pinned = crypto(:md5, { 1 => 'old', 2 => 'new' }, send_key: 1)
    assert_equal 1, Wire.decode(encode(pinned), auth: old_only).key_id
  end

  def test_mixed_algorithms_in_one_key_chain
    auth = Auth.build(type: :crypto, keys: [{ id: 1, algorithm: :md5, secret: 'a' },
                                            { id: 2, algorithm: :hmac_sha512, secret: 'b' }])
    assert_equal 64, auth.trailer_size
    md5_peer = crypto(:md5, { 1 => 'a' })
    assert_equal 2, Wire.decode(encode(auth), auth: auth).key_id
    assert_equal 1, Wire.decode(encode(md5_peer), auth: auth).key_id
  end

  def test_sequence_number_starts_at_wall_clock_and_never_goes_down
    t = 5_000
    auth = crypto(:md5, { 1 => 'k' }, clock: -> { t })
    assert_equal 5_000, auth.next_seq
    assert_equal 5_001, auth.next_seq, 'several packets in one second'
    t = 4_000
    assert_equal 5_002, auth.next_seq, 'clock went back'
    t = 9_000
    assert_equal 9_000, auth.next_seq
  end

  def test_build_rejects_bad_specs
    {
      { type: :rot13 } => /unknown authentication type/,
      { type: :simple } => /needs a password/,
      { type: :simple, password: '123456789' } => /at most 8/,
      { type: :md5, keys: {} } => /at least one key/,
      { type: :md5, keys: { 1 => 'x' * 17 } } => /at most 16/,
      { type: :md5, keys: { 256 => 'k' } } => /0\.\.255/,
      { type: :md5, keys: { 1 => '' } } => /secret missing/,
      { type: :md5, keys: { 1 => 'k' }, send_key: 3 } => /send key 3/,
      { type: :md5, keys: [{ id: 1, algorithm: :hmac_sha1, secret: 'k' }] } => /under authentication type md5/,
      { type: :crypto, keys: [{ id: 1, secret: 'k' }] } => /algorithm missing/,
      { type: :crypto, keys: [{ id: 1, algorithm: :md5, secret: 'a' }, { id: 1, algorithm: :md5, secret: 'b' }] } => /duplicate key id/,
      { type: :md5, keys: { 1 => 'k' }, password: 'p' } => /unknown authentication option/
    }.each do |spec, msg|
      e = assert_raise(ArgumentError, spec.inspect) { Auth.build(spec) }
      assert_match(msg, e.message, spec.inspect)
    end
  end

  def test_summaries_never_show_secrets
    auth = crypto(:hmac_sha256, { 1 => 'topsecret' })
    assert_not_match(/topsecret/, auth.summary.inspect + auth.to_s + auth.keys.values.inspect)
    assert_not_match(/hunter2/, Auth.build(type: :simple, password: 'hunter2').summary.inspect)
  end

  # ---- routers ----

  def lan_pair(auth_a, auth_b)
    lan = @lab.segment
    a = @lab.router('1.1.1.1', [lan, '10.0.0.1/24', { auth: auth_a }])
    b = @lab.router('2.2.2.2', [lan, '10.0.0.2/24', { auth: auth_b }])
    [lan, a, b]
  end

  def setup
    @lab = CoreLab.new
  end

  def test_md5_routers_reach_full_and_sync
    spec = { type: :md5, keys: { 1 => 'secret' } }
    _, a, b = lan_pair(spec, spec)
    @lab.start
    @lab.converge([a, b])
    assert_equal 0, a.interfaces['eth0'].stats[:drop_auth]
    assert_equal 'md5 key 1', a.interfaces['eth0'].summary[:auth]
  end

  def test_hmac_sha256_three_routers_on_a_lan
    spec = { type: :hmac_sha256, keys: { 3 => 'a long shared key, longer than thirty-two bytes' } }
    lan = @lab.segment
    rs = %w[1 2 3].map { |i| @lab.router("#{i}.#{i}.#{i}.#{i}", [lan, "10.0.0.#{i}/24", { auth: spec }]) }
    @lab.start
    @lab.run_until(120) { rs.all? { |r| r.interfaces['eth0'].state != :waiting } }
    @lab.converge(rs, adjacent: [[rs[2], rs[0]], [rs[2], rs[1]]])
  end

  def test_mismatched_keys_never_form_an_adjacency
    _, a, b = lan_pair({ type: :md5, keys: { 1 => 'one' } }, { type: :md5, keys: { 1 => 'two' } })
    @lab.start
    @lab.advance(60)
    assert_empty a.neighbors
    assert_empty b.neighbors
    assert_operator a.interfaces['eth0'].stats[:drop_auth], :>, 3
    assert(@lab.log.any? { |l| l.include?('digest mismatch') })
  end

  def test_authenticated_and_null_do_not_mix
    _, a, b = lan_pair({ type: :simple, password: 'p' }, nil)
    @lab.start
    @lab.advance(60)
    assert_empty a.neighbors
    assert_empty b.neighbors
    assert(@lab.log.any? { |l| l.include?('authentication type 0 (null), expected 1 (simple)') })
  end

  def test_replayed_packet_is_dropped
    spec = { type: :md5, keys: { 1 => 'secret' } }
    lan, a, b = lan_pair(spec, spec)
    captured = nil
    lan.drop_if do |bytes, from, _|
      captured ||= bytes.dup if from == '10.0.0.2' && bytes.getbyte(1) == Wire::HELLO
      false
    end
    @lab.start
    @lab.converge([a, b])
    before = a.interfaces['eth0'].stats[:drop_auth]
    a.interfaces['eth0'].transport.receive(captured, '10.0.0.2')
    @lab.advance(1)
    assert_equal before + 1, a.interfaces['eth0'].stats[:drop_auth]
    assert(@lab.log.any? { |l| l.include?('replayed?') })
    assert @lab.full?(a, b), 'the replay does not disturb the adjacency'
  end

  def test_key_rollover_keeps_the_adjacency
    _, a, b = lan_pair({ type: :md5, keys: { 1 => 'old' } }, { type: :md5, keys: { 1 => 'old' } })
    @lab.start
    @lab.converge([a, b])
    changes = [a, b].sum { |r| r.neighbors.sum(&:state_changes) }

    # Step 1: both learn key 2 but keep sending key 1.
    [a, b].each { |r| r.interfaces['eth0'].auth = { type: :md5, keys: { 1 => 'old', 2 => 'new' }, send_key: 1 } }
    @lab.advance(30)
    # Step 2: switch to key 2 one router at a time.
    a.interfaces['eth0'].auth = { type: :md5, keys: { 1 => 'old', 2 => 'new' } }
    @lab.advance(30)
    b.interfaces['eth0'].auth = { type: :md5, keys: { 1 => 'old', 2 => 'new' } }
    @lab.advance(30)
    # Step 3: drop key 1.
    [a, b].each { |r| r.interfaces['eth0'].auth = { type: :md5, keys: { 2 => 'new' } } }
    @lab.advance(60)

    assert @lab.full?(a, b)
    assert_equal changes, [a, b].sum { |r| r.neighbors.sum(&:state_changes) }, 'no state change during rollover'
    assert_equal 0, a.interfaces['eth0'].stats[:drop_auth] + b.interfaces['eth0'].stats[:drop_auth]
  end

  # ---- review findings ----

  def capture_hellos(lan, from_ip)
    seen = []
    lan.drop_if do |bytes, from, _|
      seen << bytes.dup if from == from_ip && bytes.getbyte(1) == Wire::HELLO
      false
    end
    seen
  end

  def test_hello_replayed_from_a_spoofed_address_makes_no_neighbor
    spec = { type: :md5, keys: { 1 => 'secret' } }
    lan, a, b = lan_pair(spec, spec)
    hellos = capture_hellos(lan, '10.0.0.2')
    @lab.start
    @lab.converge([a, b])
    eth = a.interfaces['eth0']
    10.times do
      eth.transport.receive(hellos.last, '10.0.0.77')
      @lab.advance(5)
    end
    assert_equal ['10.0.0.2'], a.neighbors.map { |n| Addr.to_s(n.address) }
    assert_equal [Addr.to_i('10.0.0.2'), Addr.to_i('10.0.0.1')].sort, [eth.dr, eth.bdr].sort
    # Each replay is dropped: by the sequence check when the neighbor sent
    # something newer since, else by the router id check.
    assert_equal 10, eth.stats[:drop_hello] + eth.stats[:drop_auth]
    assert(@lab.log.any? { |l| l.include?('is already neighbor 2.2.2.2@10.0.0.2') })
  end

  def test_packet_replayed_from_another_neighbors_address_leaves_it_alone
    spec = { type: :md5, keys: { 1 => 'secret' } }
    lan = @lab.segment
    rs = %w[1 2 3].map { |i| @lab.router("#{i}.#{i}.#{i}.#{i}", [lan, "10.0.0.#{i}/24", { auth: spec }]) }
    a = rs[0]
    hellos = capture_hellos(lan, '10.0.0.2')
    @lab.start
    @lab.converge(rs, adjacent: [[rs[2], rs[0]], [rs[2], rs[1]]])
    c_nbr = a.neighbors.find { |n| Addr.to_s(n.address) == '10.0.0.3' }
    changes = c_nbr.state_changes
    20.times do
      a.interfaces['eth0'].transport.receive(hellos.last, '10.0.0.3')
      @lab.advance(3)
    end
    assert_equal '3.3.3.3', Addr.to_s(c_nbr.router_id)
    assert c_nbr.full?
    assert_equal changes, c_nbr.state_changes
    assert(@lab.log.any? { |l| l.include?('router id 2.2.2.2 from 10.0.0.3, where neighbor 3.3.3.3@10.0.0.3 is') })
  end

  def test_a_key_change_after_a_burst_keeps_the_sequence_going_up
    spec = { type: :md5, keys: { 1 => 'secret' } }
    _, a, b = lan_pair(spec, spec)
    @lab.start
    @lab.converge([a, b])
    eth = a.interfaces['eth0']
    500.times { eth.auth.next_seq } # a burst puts it ahead of the clock
    ahead = eth.auth.next_seq
    eth.auth = spec
    assert_operator eth.auth.next_seq, :>, ahead
    eth.auth = nil
    eth.auth = { type: :hmac_sha256, keys: { 1 => 'other' } }
    assert_operator eth.auth.next_seq, :>, ahead, 'through null and another algorithm too'

    eth.auth = spec
    changes = b.neighbors.first.state_changes
    @lab.advance(60)
    assert_equal changes, b.neighbors.first.state_changes
    assert_equal 0, b.interfaces['eth0'].stats[:drop_auth]
  end

  def test_neighbor_restart_forms_the_adjacency_again
    spec = { type: :md5, keys: { 1 => 'secret' } }
    _, a, b = lan_pair(spec, spec)
    @lab.start
    @lab.converge([a, b])
    b.stop
    @lab.advance(60)
    assert_empty a.neighbors
    b.start
    @lab.converge([a, b])
  end

  def test_sequence_stops_at_the_top_instead_of_wrapping
    t = Auth::Sequence::MAX - 1
    seq = Auth::Sequence.new(-> { t })
    assert_equal Auth::Sequence::MAX - 1, seq.next
    assert_equal Auth::Sequence::MAX, seq.next
    assert_equal Auth::Sequence::MAX, seq.next
    t = 2**40
    assert_equal Auth::Sequence::MAX, seq.next
  end

  def test_auth_data_length_and_key_id_edges
    auth = crypto(:md5, { 0 => 'zero' })
    bytes = encode(auth)
    assert_equal 0, Wire.decode(bytes, auth: auth).key_id, 'key id 0 is a key like any other'
    [0, 255].each do |len|
      bad = bytes.dup.tap { |b| b.setbyte(19, len) }
      assert_raise(Wire::AuthError, "length #{len}") { Wire.decode(bad, auth: auth) }
    end
  end

  def test_hmac_key_lengths_around_the_hash_size
    { 'SHA1' => [:hmac_sha1, 20], 'SHA256' => [:hmac_sha256, 32] }.each do |digest, (type, len)|
      [len, len + 1, 64].each do |klen|
        secret = 's' * klen
        bytes = encode(crypto(type, { 1 => secret }))
        pkt = packet_part(bytes)
        key = klen > len ? OpenSSL::Digest.digest(digest, secret) : secret
        expected = OpenSSL::HMAC.digest(digest, key, pkt + ([0x878F_E1F3].pack('N') * (len / 4)))
        assert_equal expected, bytes.byteslice(pkt.bytesize, len), "#{type} with a #{klen} byte key"
      end
    end
  end

  def test_decode_takes_strings_in_any_encoding
    auth = crypto(:hmac_sha256, { 1 => 'k' })
    utf8 = encode(auth).dup.force_encoding(Encoding::UTF_8)
    assert_equal HELLO, Wire.decode(utf8, auth: auth).body
  end

  def test_fuzzed_packets_only_raise_wire_errors
    rng = Random.new(7)
    auths = [Auth.build(nil), Auth.build(type: :simple, password: 'p'), crypto(:md5, { 1 => 'k' }),
             crypto(:hmac_sha512, { 1 => 'k' })]
    lsu = Wire::LinkStateUpdate.new(lsas: [Lsa.build(type: 5, ls_id: 1, advr: 2, seq: Lsa::INITIAL_SEQ,
                                                     body: [0xffffff00, 20, 0, 0].pack('N4'))])
    auths.each do |auth|
      [HELLO, lsu].each do |body|
        good = encode(auth, body)
        1500.times do
          b = good.dup
          case rng.rand(4)
          when 0 then rng.rand(1..4).times { i = rng.rand(b.bytesize); b.setbyte(i, rng.rand(256)) }
          when 1 then b = b.byteslice(0, rng.rand(b.bytesize))
          when 2 then b << Random.bytes(rng.rand(1..40))
          when 3 then b[2, 2] = [rng.rand(65_536)].pack('n')
          end
          begin
            Wire.decode(b, auth: auth)
          rescue Wire::Error
            nil
          end
        end
      end
    end
    assert true, 'nothing but Wire::Error escaped'
  end

  def test_big_digest_still_fits_the_mtu
    spec = { type: :hmac_sha512, keys: { 1 => 'k' } }
    seg = @lab.segment
    a = @lab.router('1.1.1.1', [seg, '10.0.12.1/30', { type: :p2p, mtu: 576, auth: spec }])
    b = @lab.router('2.2.2.2', [seg, '10.0.12.2/30', { type: :p2p, mtu: 576, auth: spec }])
    sizes = []
    seg.drop_if { |bytes, _, _| (sizes << bytes.bytesize) && false }
    # Enough externals for several DD pages and updates.
    @lab.loop.post do
      200.times do |i|
        body = [0xffffff00, 0x8000_0000 | 20, 0, 0].pack('NNNN')
        a.as_lsdb.install(Lsa.build(type: 5, ls_id: (50 << 24) + (i << 8), advr: '7.7.7.7', seq: Lsa::INITIAL_SEQ, body: body))
      end
    end
    @lab.start
    @lab.converge([a, b])
    assert_operator sizes.max, :<=, 576 - 20, 'every packet, digest included, fits the MTU'
    assert_equal 200, b.as_lsdb.size
  end
end
