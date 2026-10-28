# frozen_string_literal: true

require 'test/unit'
require 'json'
require 'ospfv2'
require 'ospfv2/core/wire'
require 'ospfv2/dissect'

# The dissector against packets built with ospfd's own encoder: every
# packet type, every LSA type the encoder makes, authentication, broken
# frames. The rule checked everywhere: every byte belongs to exactly one
# field, or to bit fields whose masks share it without overlap.
class TestDissect < Test::Unit::TestCase
  include OSPFv2
  W = Core::Wire
  A = Core::Addr

  RID = A.to_i('2.2.2.2')
  AREA = 0

  # An Ethernet frame around an IPv4 packet around +ospf+, padded to the
  # Ethernet minimum like a real capture.
  def frame(ospf, src: '10.99.0.20', dst: '224.0.0.5', pad: true)
    ip = [0x45, 0xc0, 20 + ospf.bytesize, 0x1234, 0, 1, 89, 0, A.to_i(src), A.to_i(dst)].pack('CCnnnCCnNN')
    sum = ip.unpack('n*').sum
    sum = (sum & 0xffff) + (sum >> 16) while sum > 0xffff
    ip[10, 2] = [~sum & 0xffff].pack('n')
    eth = ['01005e000005', '0242ac110002'].pack('H12H12') + [0x0800].pack('n')
    f = (eth + ip + ospf).b
    f << ("\0" * (60 - f.bytesize)) if pad && f.bytesize < 60
    f
  end

  def encode(body, auth: W::NULL_AUTH) = W.encode(body, router_id: RID, area_id: AREA, auth: auth)

  def hello = W::Hello.new(netmask: A.to_i('255.255.255.0'), hello_interval: 2, options: 0x02, priority: 1,
                           dead_interval: 8, dr: A.to_i('10.99.0.20'), bdr: 0, neighbors: [A.to_i('1.1.1.1'), A.to_i('3.3.3.3')])

  def lsas
    [Core::Lsa.router(advr: '2.2.2.2', seq: -0x7fff_fffe, flags: 0x03,
                      links: [{ id: '10.99.0.20', data: '10.99.0.20', type: 2, metric: 10 },
                              { id: '192.0.2.0', data: '255.255.255.0', type: 3, metric: 1 }]),
     Core::Lsa.network(dr_address: '10.99.0.20', advr: '2.2.2.2', mask: '255.255.255.0',
                       attached: %w[2.2.2.2 1.1.1.1 3.3.3.3], seq: -0x7fff_ffff),
     Core::Lsa.build(type: 3, ls_id: '30.0.0.0', advr: '10.0.0.1', seq: -0x7fff_ffff,
                     body: [A.to_i('255.255.255.0'), 0, 20].pack('NCn').insert(5, "\0")),
     Core::Lsa.build(type: 5, ls_id: '50.0.0.0', advr: '10.0.0.1', seq: -0x7fff_ffff, age: 33,
                     body: [A.to_i('255.255.255.0'), 0x80, 0, 20, 0, 7].pack('NCCnNN')),
     Core::Lsa.build(type: 10, ls_id: '1.0.0.7', advr: '2.2.2.2', seq: -0x7fff_ffff, body: "\x00\x01\x00\x04abcd".b)]
  end

  # Every byte in one field, or shared by bit fields without overlap.
  def assert_every_byte_owned(d)
    owners = Array.new(d.length) { [] }
    d.leaves.each do |f|
      f.length.times do |i|
        m = f.mask ? (f.mask >> (8 * (f.length - 1 - i))) & 0xff : 0xff
        owners[f.offset + i] << [f.name, m] unless m.zero?
      end
    end
    owners.each_with_index do |o, i|
      assert(!o.empty?, "byte #{i} belongs to no field")
      masks = o.map(&:last)
      assert_equal 0xff, masks.reduce(0, :|), "byte #{i}: bits left out by #{o.inspect}"
      assert_equal masks.sum, masks.reduce(0, :|), "byte #{i}: fields overlap: #{o.inspect}"
    end
  end

  def find(fields, name) = fields.flat_map { [_1, *(_1.children ? find_all(_1.children) : [])] }.find { _1.name == name }
  def find_all(fields) = fields.flat_map { [_1, *(_1.children ? find_all(_1.children) : [])] }

  def test_hello
    d = Dissect.frame(frame(encode(hello)))
    assert_equal [], d.errors
    assert_every_byte_owned(d)
    assert_equal 'Hello 10.99.0.20 > 224.0.0.5, DR 10.99.0.20, 2 neighbors', d.summary
    all = find_all(d.fields)
    assert_equal %w[1.1.1.1 3.3.3.3], all.select { _1.name == 'neighbor' }.map(&:value)
    assert_equal({ ok: true }, all.find { _1.name == 'header checksum' }.check)
    assert_equal({ ok: true }, all.find { _1.name == 'checksum' && _1.offset == 14 + 20 + 12 }.check)
    opts = all.find { _1.name == 'options' }
    assert_equal ['E', 14 + 20 + 24 + 6, 1], [opts.show, opts.offset, opts.length]
    e = opts.children.find { _1.name == 'E' }
    assert_equal [1, 0x02, '1'], [e.value, e.mask, e.show]
    assert_equal 'OSPF', d.fields.last.name
  end

  def test_dd_with_lsa_headers_and_flags
    dd = W::DatabaseDescription.new(mtu: 1500, options: 0x42, flags: 7, seq: 4711, headers: lsas.map(&:header))
    d = Dissect.frame(frame(encode(dd), dst: '10.99.0.30'))
    assert_equal [], d.errors
    assert_every_byte_owned(d)
    assert_match(/\ADatabase Description 10.99.0.20 > 10.99.0.30 I M MS seq 4711, 5 headers\z/, d.summary)
    all = find_all(d.fields)
    flags = all.find { _1.name == 'flags' }
    assert_equal [%w[I M MS reserved], [0x04, 0x02, 0x01, 0xf8]], [flags.children.map(&:name), flags.children.map(&:mask)]
    assert_equal 'O E', all.find { _1.name == 'options' }.show
    hdrs = all.select { _1.name == 'LSA header' }
    assert_equal [1, 2, 3, 5, 10], hdrs.map { _1.lsa[:type] }
    assert_equal({ type: 1, ls_id: '2.2.2.2', advr: '2.2.2.2', seq: '0x80000002' }, hdrs.first.lsa)
  end

  def test_ls_update_decodes_every_lsa_and_checks_fletcher
    d = Dissect.frame(frame(encode(W::LinkStateUpdate.new(lsas: lsas))))
    assert_equal [], d.errors
    assert_every_byte_owned(d)
    all = find_all(d.fields)
    names = all.select { _1.lsa && _1.name.end_with?('LSA') }.map(&:name)
    assert_equal ['Router LSA', 'Network LSA', 'Summary LSA', 'AS external LSA', 'Opaque area LSA'], names
    assert(all.select { _1.name == 'checksum' && _1.check && _1.offset > 70 }.all? { _1.check[:ok] }, 'Fletcher')
    links = all.select { _1.name == 'link' }
    assert_equal ['transit 10.99.0.20 metric 10', 'stub 192.0.2.0 metric 1'], links.map(&:show)
    rflags = all.find { _1.name == 'flags' && _1.children.any? { |c| c.name == 'B' } }
    assert_equal 'E B', rflags.show
    assert_equal %w[2.2.2.2 1.1.1.1 3.3.3.3], all.select { _1.name == 'attached router' }.map(&:value)
    ext = all.find { _1.name == 'external route' }
    assert_equal ['E2 metric 20', 7], [ext.show, ext.children.find { _1.name == 'route tag' }.value]
    assert_equal 'opaque type 1, id 7', all.find { _1.name == 'link state id' && _1.children }.show
    assert_equal '33 s', all.select { _1.name == 'LS age' }[3].show
  end

  def test_ls_request_and_ack
    req = W::LinkStateRequest.new(requests: [[1, RID, RID], [5, A.to_i('50.0.0.0'), A.to_i('10.0.0.1')]])
    d = Dissect.frame(frame(encode(req)))
    assert_equal [], d.errors
    assert_every_byte_owned(d)
    assert_equal [{ type: 1, ls_id: '2.2.2.2', advr: '2.2.2.2' }, { type: 5, ls_id: '50.0.0.0', advr: '10.0.0.1' }],
                 find_all(d.fields).select { _1.name == 'request' }.map(&:lsa)
    a = Dissect.frame(frame(encode(W::LinkStateAck.new(headers: lsas.first(2).map(&:header)))))
    assert_equal [], a.errors
    assert_every_byte_owned(a)
    assert_match(/LS Ack .*, 2 headers\z/, a.summary)
    # An empty Ack is shorter than Ethernet's minimum: the rest is padding.
    e = Dissect.frame(frame(encode(W::LinkStateAck.new(headers: []))))
    assert_equal [], e.errors
    assert_every_byte_owned(e)
    assert_equal ['Ethernet padding', 2], e.fields.last.then { [_1.name, _1.length] }
  end

  def test_cryptographic_authentication_and_its_trailer
    keys = [Core::Auth::Key.new(id: 7, algorithm: :md5, secret: 'lab')]
    auth = Core::Auth::Crypto.new(keys: keys, sequence: Core::Auth::Sequence.new(-> { 1_000 }))
    d = Dissect.frame(frame(encode(hello, auth: auth)))
    assert_equal [], d.errors
    assert_every_byte_owned(d)
    all = find_all(d.fields)
    assert_equal 'key 7, seq 1000', all.find { _1.name == 'authentication' }.show
    assert_equal [16, '16 bytes (digest)'], all.find { _1.name == 'authentication data' }.then { [_1.length, _1.show] }
    s = Dissect.frame(frame(encode(hello, auth: Core::Auth::Simple.new('s3cret'))))
    assert_equal '********', find_all(s.fields).find { _1.name == 'password' }.value
    refute_match(/s3cret|733363726574/, JSON.generate(s.to_h), 'the password never shows')
  end

  def test_broken_frames_say_why_and_still_own_every_byte
    good = frame(encode(W::LinkStateUpdate.new(lsas: lsas)), pad: false)
    bad = good.dup
    # One bit inside the first LSA (Fletcher cannot tell 0x00 from 0xff).
    bad[14 + 20 + 24 + 4 + 30] = (bad.getbyte(14 + 20 + 24 + 4 + 30) ^ 0x01).chr
    d = Dissect.frame(bad)
    assert_match(/Router 2.2.2.2 2.2.2.2: Fletcher checksum is wrong/, d.errors.join(' '))
    assert_match(/OSPF checksum is wrong/, d.errors.join(' '))
    assert_every_byte_owned(d)
    cut = Dissect.frame(good.byteslice(0, 14 + 20 + 24 + 4 + 50))
    refute_empty cut.errors
    assert_every_byte_owned(cut)
    tiny = Dissect.frame(good.byteslice(0, 30))
    refute_empty tiny.errors
    assert_every_byte_owned(tiny)
    arp = Dissect.frame(['ffffffffffff', '0242ac110002', '0806', '00' * 28].pack('H12H12H4H*'))
    assert_equal 'not OSPF', arp.summary
    assert_every_byte_owned(arp)
  end

  def test_from_the_ip_header_and_to_h
    ospf = encode(hello)
    full = frame(ospf, pad: false)
    d = Dissect.frame(full.byteslice(14..), link: :ip)
    assert_equal [], d.errors
    assert_every_byte_owned(d)
    h = d.to_h
    assert_equal %w[IPv4 OSPF], h[:fields].map { _1[:name] }
    assert_equal 0, h[:fields][0][:offset]
    assert JSON.generate(h)
  end
end
