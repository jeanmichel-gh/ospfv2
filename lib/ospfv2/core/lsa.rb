# frozen_string_literal: true

require_relative 'addr'
require_relative '../infra/ospf_constants'

module OSPFv2
  module Core
    # Fletcher checksum over an LSA without its age (RFC 2328 12.1.7).
    module Fletcher
      module_function

      # The two checksum bytes for +lsa+, whose bytes 16 and 17 are ignored.
      def compute(lsa)
        bytes = lsa.byteslice(2..).bytes
        bytes[14] = bytes[15] = 0 # checksum field, offset 16 in the LSA
        c0 = c1 = 0
        bytes.each do |b|
          c0 += b
          c0 -= 255 if c0 >= 255
          c1 += c0
          c1 -= 255 if c1 >= 255
        end
        x = ((bytes.size - 15) * c0 - c1) % 255
        x = 255 if x.zero?
        y = 510 - c0 - x
        y -= 255 if y > 255
        [x, y].pack('CC')
      end

      def valid?(lsa)
        c0 = c1 = 0
        lsa.byteslice(2..).each_byte do |b|
          c0 += b
          c0 -= 255 if c0 >= 255
          c1 += c0
          c1 -= 255 if c1 >= 255
        end
        c0.zero? && c1.zero?
      end
    end

    # LSA header fields and the RFC 2328 13.1 "which is newer" rule.
    # Shared by full LSAs and the bare headers carried in DD and Ack
    # packets.
    module LsaFields
      TYPES = {
        1 => :router, 2 => :network, 3 => :summary, 4 => :asbr_summary, 5 => :external,
        7 => :nssa, 9 => :opaque_link, 10 => :opaque_area, 11 => :opaque_as
      }.freeze

      # Sequence numbers are signed (RFC 2328 12.1.6).
      INITIAL_SEQ = -0x7fff_ffff
      MAX_SEQ     = 0x7fff_ffff

      def type_name
        TYPES.fetch(type, type)
      end

      def key
        [type, ls_id, advr]
      end

      def max_age?
        age >= OSPFv2::MaxAge
      end

      # +1 if self is the newer instance, -1 if other is, 0 if they are
      # the same instance (RFC 2328 13.1).
      def compare(other)
        return seq <=> other.seq unless seq == other.seq
        return checksum <=> other.checksum unless checksum == other.checksum
        mine = [age, OSPFv2::MaxAge].min
        theirs = [other.age, OSPFv2::MaxAge].min
        return +1 if mine == OSPFv2::MaxAge && theirs < OSPFv2::MaxAge
        return -1 if theirs == OSPFv2::MaxAge && mine < OSPFv2::MaxAge
        return 0 if (mine - theirs).abs <= OSPFv2::MaxAgeDiff
        mine < theirs ? +1 : -1
      end

      def newer_than?(other)
        compare(other).positive?
      end

      def same_instance?(other)
        compare(other).zero?
      end

      def id_string
        "#{type_name} #{Addr.to_s(ls_id)} #{Addr.to_s(advr)}"
      end

      # The instance key events carry, to tie one LSA instance together
      # across routers and tools: type, Link State ID, advertising router,
      # sequence number.
      def instance_fields
        { lsa_type: type_name.to_s, ls_id: Addr.to_s(ls_id), advr: Addr.to_s(advr), seq: format('0x%08x', seq & 0xffff_ffff) }
      end

      def to_s
        format('%-12s %-15s %-15s age %4d seq 0x%08x csum 0x%04x len %d',
               type_name, Addr.to_s(ls_id), Addr.to_s(advr), age, seq & 0xffff_ffff, checksum, length)
      end
    end

    # The 20-byte LSA header, as carried in DD and LS Ack packets.
    class LsaHeader
      include LsaFields

      SIZE = 20
      attr_reader :age, :options, :type, :ls_id, :advr, :seq, :checksum, :length

      def self.parse(bytes)
        raise ArgumentError, "LSA header needs 20 bytes, got #{bytes.bytesize}" if bytes.bytesize < SIZE
        age, options, type, ls_id, advr, seq, csum, len = bytes.unpack('nCCNNNnn')
        new(age: age, options: options, type: type, ls_id: ls_id, advr: advr,
            seq: seq >= 0x8000_0000 ? seq - 0x1_0000_0000 : seq, checksum: csum, length: len)
      end

      def initialize(age:, options:, type:, ls_id:, advr:, seq:, checksum:, length:)
        @age = age
        @options = options
        @type = type
        @ls_id = ls_id
        @advr = advr
        @seq = seq
        @checksum = checksum
        @length = length
        freeze
      end

      def encode
        [@age, @options, @type, @ls_id, @advr, @seq & 0xffff_ffff, @checksum, @length].pack('nCCNNNnn')
      end

      def header
        self
      end

      def ==(other)
        other.respond_to?(:encode_header) ? encode == other.encode_header : (other.is_a?(LsaHeader) && encode == other.encode)
      end
      alias eql? ==

      def hash
        encode.hash
      end

      alias encode_header encode
    end

    # A complete LSA kept as the bytes it travels in. The core never
    # re-encodes an LSA it received: it floods exactly what it got, with
    # only the age changed, so the checksum stays valid.
    class Lsa
      include LsaFields

      class Error < StandardError; end

      attr_reader :bytes, :age, :options, :type, :ls_id, :advr, :seq, :checksum, :length

      # Parses one LSA from the start of +bytes+. Raises Lsa::Error.
      def self.parse(bytes)
        raise Error, "LSA too short (#{bytes.bytesize} bytes)" if bytes.bytesize < LsaHeader::SIZE
        len = bytes.byteslice(18, 2).unpack1('n')
        raise Error, "bad LSA length #{len}" if len < LsaHeader::SIZE
        raise Error, "LSA length #{len} past the end of the packet (#{bytes.bytesize})" if len > bytes.bytesize
        new(bytes.byteslice(0, len))
      end

      # Builds an LSA and fills in length and checksum.
      def self.build(type:, ls_id:, advr:, seq:, body:, options: 0x02, age: 0)
        hdr = [age, options, type, Addr.to_i(ls_id), Addr.to_i(advr), seq & 0xffff_ffff, 0,
               LsaHeader::SIZE + body.bytesize].pack('nCCNNNnn')
        raw = (hdr + body).b
        raw[16, 2] = Fletcher.compute(raw)
        new(raw)
      end

      def initialize(bytes)
        @bytes = bytes.b.freeze
        h = LsaHeader.parse(@bytes)
        @age = h.age
        @options = h.options
        @type = h.type
        @ls_id = h.ls_id
        @advr = h.advr
        @seq = h.seq
        @checksum = h.checksum
        @length = h.length
        freeze
      end

      def header
        LsaHeader.parse(@bytes)
      end

      def encode_header
        @bytes.byteslice(0, LsaHeader::SIZE)
      end

      def body
        @bytes.byteslice(LsaHeader::SIZE..)
      end

      def checksum_ok?
        Fletcher.valid?(@bytes)
      end

      # The same LSA with another age. The age is outside the checksum.
      def with_age(age)
        age = [[age, 0].max, OSPFv2::MaxAge].min
        return self if age == @age
        raw = @bytes.dup
        raw[0, 2] = [age].pack('n')
        Lsa.new(raw)
      end

      def ==(other)
        other.is_a?(Lsa) && @bytes == other.bytes
      end
      alias eql? ==

      def hash
        @bytes.hash
      end

      # -- body decoding for the types the core originates and reads --

      LINK_TYPES = { 1 => :p2p, 2 => :transit, 3 => :stub, 4 => :virtual }.freeze

      RouterLink = Struct.new(:type, :id, :data, :metric) do
        def type_name = LINK_TYPES.fetch(type, type)

        def to_s
          "#{type_name} id #{Addr.to_s(id)} data #{Addr.to_s(data)} metric #{metric}"
        end
      end

      # Router-LSA: [flags, links]. flags bit 0 B, bit 1 E, bit 2 V.
      def router_body
        raise Error, 'not a router-LSA' unless type == 1
        b = body
        raise Error, "router-LSA body too short (#{b.bytesize} bytes)" if b.bytesize < 4
        flags, _, count = b.unpack('CCn')
        links = []
        off = 4
        count.times do
          raise Error, "router-LSA says #{count} links, truncated at #{links.size}" if off + 12 > b.bytesize
          id, data, ltype, ntos, metric = b.byteslice(off, 12).unpack('NNCCn')
          links << RouterLink.new(ltype, id, data, metric)
          off += 12 + ntos * 4
        end
        raise Error, 'router-LSA TOS metrics run past the end' if off > b.bytesize
        [flags, links]
      end

      def router_links
        router_body[1]
      end

      # Network-LSA: [mask, attached router ids].
      def network_body
        raise Error, 'not a network-LSA' unless type == 2
        b = body
        raise Error, "network-LSA body of #{b.bytesize} bytes" if b.bytesize < 8 || (b.bytesize % 4).nonzero?
        mask, *routers = b.unpack('N*')
        [mask, routers]
      end

      # The body as plain data, the same for ospfd's API and the simulator's:
      # router flags and links, network mask and attached routers, summary
      # and external mask, metric, type, forwarding address and tag. Other
      # types give {}. A body that does not decode gives { error: }.
      def detail
        case type
        when 1
          flags, links = router_body
          { flags: { b: flags[0] == 1, e: flags[1] == 1, v: flags[2] == 1 },
            links: links.map { |k| { type: k.type_name, id: Addr.to_s(k.id), data: Addr.to_s(k.data), metric: k.metric } } }
        when 2
          mask, routers = network_body
          { mask: Addr.to_s(mask), attached: routers.map { |x| Addr.to_s(x) } }
        when 3, 4, 5, 7
          b = body
          raise Error, "type #{type} LSA body of #{b.bytesize} bytes" if b.bytesize < 8
          mask, metric = b.unpack('NN')
          d = { mask: Addr.to_s(mask), metric: metric & 0xff_ffff }
          if type >= 5 && b.bytesize >= 16
            _, _, fwd, tag = b.unpack('NNNN')
            d.merge!(external_type: metric >> 31 == 1 ? 2 : 1, forwarding: Addr.to_s(fwd), tag: tag)
          end
          d
        else {}
        end
      rescue Error => e
        { error: e.message }
      end

      def self.router(advr:, seq:, links:, flags: 0, options: 0x02, age: 0)
        body = [flags, 0, links.size].pack('CCn')
        links.each do |l|
          body << [Addr.to_i(l[:id]), Addr.to_i(l[:data]), l[:type], 0, l[:metric]].pack('NNCCn')
        end
        build(type: 1, ls_id: advr, advr: advr, seq: seq, body: body, options: options, age: age)
      end

      def self.network(dr_address:, advr:, mask:, attached:, seq:, options: 0x02, age: 0)
        body = [Addr.to_i(mask), *attached.map { |r| Addr.to_i(r) }].pack('N*')
        build(type: 2, ls_id: dr_address, advr: advr, seq: seq, body: body, options: options, age: age)
      end
    end
  end
end
