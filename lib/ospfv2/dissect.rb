# frozen_string_literal: true

require_relative 'core/addr'
require_relative 'core/auth'
require_relative 'core/lsa'

module OSPFv2
  # Dissects captured OSPF frames for a packet decoder: every field with its
  # byte offset, length and, for bits, its mask, so a decoder can light up
  # the bytes of a field and the field of a byte. Every byte of the frame
  # belongs to a field; reserved bytes and bits are fields too. Checksums
  # are verified (IPv4 header, OSPF packet, each LSA's Fletcher).
  #
  #   d = Dissect.frame(bytes)                  # Ethernet, as tcpdump gives it
  #   d = Dissect.frame(bytes, link: :ip)       # starting at the IPv4 header
  #   d.to_h  # => { summary:, length:, fields: [...], errors: [...] }
  #
  # A field: { name:, offset:, length:, value:, show:, mask:, children:,
  # check: { ok:, ... }, lsa: { type:, ls_id:, advr:, seq: } }. Offsets are
  # from the start of the frame. A mask is the field's bits within its bytes
  # (big endian). An LSA, or an LSA header in a DD or Ack packet, carries
  # its instance key in +lsa+, the key the console follows an LSA by.
  #
  # The dissector never raises on a bad frame: what does not parse becomes
  # a "truncated" or "data" field, and the reason goes to +errors+.
  module Dissect
    Field = Struct.new(:name, :offset, :length, :value, :show, :mask, :children, :check, :lsa, keyword_init: true) do
      def to_h
        h = { name: name, offset: offset, length: length }
        h[:value] = value unless value.nil?
        h[:show] = show unless show.nil?
        h[:mask] = mask if mask
        h[:check] = check if check
        h[:lsa] = lsa if lsa
        h[:children] = children.map(&:to_h) if children && !children.empty?
        h
      end

      # The fields without children: the ones that own bytes.
      def leaves = children && !children.empty? ? children.flat_map(&:leaves) : [self]
    end

    Result = Struct.new(:summary, :length, :fields, :errors, keyword_init: true) do
      def to_h = { summary: summary, length: length, fields: fields.map(&:to_h), errors: errors }
      def leaves = fields.flat_map(&:leaves)
    end

    LINKS = { 1 => :ethernet, 101 => :ip, 12 => :ip, 113 => :sll, 228 => :ip }.freeze

    PACKET_TYPES = { 1 => 'Hello', 2 => 'Database Description', 3 => 'LS Request', 4 => 'LS Update', 5 => 'LS Ack' }.freeze
    LSA_TYPES = { 1 => 'Router', 2 => 'Network', 3 => 'Summary', 4 => 'ASBR summary', 5 => 'AS external',
                  7 => 'NSSA external', 9 => 'Opaque link', 10 => 'Opaque area', 11 => 'Opaque AS' }.freeze
    AUTYPES = { 0 => 'none', 1 => 'simple password', 2 => 'cryptographic' }.freeze
    # Options (RFC 2328 A.2, RFC 5250, RFC 3101): bit => name.
    OPTIONS = { 0x80 => 'DN', 0x40 => 'O', 0x20 => 'DC', 0x10 => 'L', 0x08 => 'N/P', 0x04 => 'MC', 0x02 => 'E', 0x01 => 'MT' }.freeze
    LINK_TYPES = { 1 => 'point-to-point', 2 => 'transit', 3 => 'stub', 4 => 'virtual link' }.freeze

    module_function

    def frame(bytes, link: :ethernet)
      Builder.new(bytes.b).run(link)
    end

    # Reads a frame field by field, keeping the offsets.
    class Builder
      def initialize(bytes)
        @b = bytes
        @errors = []
        @summary = nil
      end

      def run(link)
        fields = []
        ip = case link
             when :ethernet then ethernet(fields)
             when :sll then sll(fields)
             else 0
             end
        if ip && ip < @b.bytesize
          ip_end = ipv4(fields, ip)
          rest(fields, ip_end, 'Ethernet padding') if ip_end
        elsif ip.nil?
          rest(fields, fields.sum(&:length), 'data')
        end
        Result.new(summary: @summary || 'not OSPF', length: @b.bytesize, fields: fields.compact, errors: @errors)
      end

      private

      # ---- reading helpers

      def room?(off, len, what)
        return true if off + len <= @b.bytesize
        @errors << "#{what}: needs #{len} bytes at #{off}, the frame ends at #{@b.bytesize}"
        false
      end

      def u8(off) = @b.getbyte(off)
      def u16(off) = @b.byteslice(off, 2).unpack1('n')
      def u24(off) = (u8(off) << 16) | u16(off + 1)
      def u32(off) = @b.byteslice(off, 4).unpack1('N')
      def ip4(off) = Core::Addr.to_s(u32(off))
      def hex(off, len) = @b.byteslice(off, len).unpack1('H*')

      def field(name, off, len, value = nil, show = nil, **more)
        Field.new(name: name, offset: off, length: len, value: value, show: show, **more)
      end

      def num(name, off, len, show = nil)
        v = case len
            when 1 then u8(off)
            when 2 then u16(off)
            when 3 then u24(off)
            else u32(off)
            end
        field(name, off, len, v, show)
      end

      def addr(name, off) = field(name, off, 4, ip4(off), ip4(off))

      # A byte or word of bits: each named bit, and what is left as reserved.
      def bits(name, off, len, names, show_value: nil)
        v = len == 1 ? u8(off) : u16(off)
        full = len == 1 ? 0xff : 0xffff
        kids = names.map do |mask, n|
          bit_show = (mask & (mask - 1)).zero? ? ((v & mask).zero? ? '0' : '1') : nil
          field(n, off, len, (v & mask) >> mask.to_s(2).reverse.index('1'), bit_show, mask: mask)
        end
        rsvd = full & ~names.keys.reduce(0, :|)
        kids << field('reserved', off, len, v & rsvd, nil, mask: rsvd) unless rsvd.zero?
        set = names.select { |m, _| (m & (m - 1)).zero? && (v & m).positive? }.values
        field(name, off, len, v, show_value || (set.empty? ? format('0x%02x', v) : set.join(' ')), children: kids)
      end

      def options(off) = bits('options', off, 1, OPTIONS)

      def rest(fields, off, name)
        return if off >= @b.bytesize
        fields << field(name, off, @b.bytesize - off, hex(off, @b.bytesize - off))
      end

      def truncated(off, upto)
        len = [upto, @b.bytesize].min - off
        field('truncated', off, len, hex(off, len)) if len.positive?
      end

      # ---- link layers

      def ethernet(fields)
        return nil unless room?(0, 14, 'Ethernet header')
        mac = ->(o) { @b.byteslice(o, 6).unpack('C6').map { format('%02x', _1) }.join(':') }
        kids = [field('destination', 0, 6, mac.(0), mac.(0)), field('source', 6, 6, mac.(6), mac.(6))]
        off = 12
        type = u16(off)
        while type == 0x8100 && room?(off, 6, 'VLAN tag')
          kids << field('VLAN tag', off, 4, u16(off + 2) & 0x0fff, "VLAN #{u16(off + 2) & 0x0fff}")
          off += 4
          type = u16(off)
        end
        kids << field('ethertype', off, 2, type, format('0x%04x%s', type, type == 0x0800 ? ' IPv4' : ''))
        fields << field('Ethernet', 0, off + 2, nil, "#{mac.(6)} > #{mac.(0)}", children: kids)
        type == 0x0800 ? off + 2 : (@errors << format('ethertype 0x%04x is not IPv4', type)) && nil
      end

      def sll(fields)
        return nil unless room?(0, 16, 'Linux cooked header')
        kids = [num('packet type', 0, 2), num('link type', 2, 2), num('address length', 4, 2),
                field('address', 6, 8, hex(6, 8)), num('protocol', 14, 2, format('0x%04x', u16(14)))]
        fields << field('Linux cooked capture', 0, 16, nil, nil, children: kids)
        u16(14) == 0x0800 ? 16 : nil
      end

      # ---- IPv4 (RFC 791). Returns where the IP packet ends.

      def ipv4(fields, off)
        return (fields << truncated(off, @b.bytesize)) && nil unless room?(off, 20, 'IPv4 header')
        ihl = (u8(off) & 0x0f) * 4
        total = u16(off + 2)
        kids = [field('version', off, 1, u8(off) >> 4, (u8(off) >> 4).to_s, mask: 0xf0),
                field('header length', off, 1, u8(off) & 0x0f, "#{ihl} bytes", mask: 0x0f),
                field('DSCP', off + 1, 1, u8(off + 1) >> 2, nil, mask: 0xfc),
                field('ECN', off + 1, 1, u8(off + 1) & 3, nil, mask: 0x03),
                num('total length', off + 2, 2),
                num('identification', off + 4, 2, format('0x%04x', u16(off + 4))),
                bits('flags and fragment', off + 6, 2, { 0x4000 => 'DF', 0x2000 => 'MF', 0x1fff => 'fragment offset' }),
                num('TTL', off + 8, 1),
                num('protocol', off + 9, 1, u8(off + 9) == 89 ? '89 OSPF' : u8(off + 9).to_s)]
        csum_ok = room?(off, ihl, 'IPv4 header') && ipsum(off, ihl).zero?
        kids << field('header checksum', off + 10, 2, u16(off + 10), format('0x%04x', u16(off + 10)), check: { ok: csum_ok })
        kids << addr('source', off + 12) << addr('destination', off + 16)
        kids << field('options', off + 20, ihl - 20, hex(off + 20, ihl - 20)) if ihl > 20 && room?(off, ihl, 'IPv4 options')
        @errors << 'IPv4 header checksum is wrong' unless csum_ok
        fields << field('IPv4', off, ihl, nil, "#{ip4(off + 12)} > #{ip4(off + 16)}", children: kids)
        ip_end = [off + total, @b.bytesize].min
        if u8(off + 9) == 89 && total > ihl
          ospf(fields, off + ihl, ip_end, ip4(off + 12), ip4(off + 16))
        elsif total > ihl
          fields << field('payload', off + ihl, ip_end - off - ihl, hex(off + ihl, ip_end - off - ihl))
        end
        ip_end
      end

      def ipsum(off, len)
        sum = @b.byteslice(off, len).unpack('n*').sum
        sum = (sum & 0xffff) + (sum >> 16) while sum > 0xffff
        ~sum & 0xffff
      end

      # ---- OSPF (RFC 2328 A.3)

      def ospf(fields, off, ip_end, src, dst)
        return fields << truncated(off, ip_end) unless room?(off, 24, 'OSPF header')
        type = u8(off + 1)
        len = u16(off + 2)
        autype = u16(off + 14)
        name = PACKET_TYPES.fetch(type, "type #{type}")
        hdr = [num('version', off, 1), field('type', off + 1, 1, type, "#{type} #{name}"),
               num('packet length', off + 2, 2), addr('router id', off + 4), addr('area id', off + 8)]
        body_end = [off + len, ip_end].min
        csum = u16(off + 12)
        csum_check = if autype == Core::Auth::CRYPTO
                       { ok: csum.zero?, note: 'zero with cryptographic authentication' }
                     else
                       { ok: len <= ip_end - off && Core::Auth.inet_checksum(@b.byteslice(off, len)).zero? }
                     end
        @errors << 'OSPF checksum is wrong' unless csum_check[:ok]
        hdr << field('checksum', off + 12, 2, csum, format('0x%04x', csum), check: csum_check)
        hdr << field('AuType', off + 14, 2, autype, "#{autype} #{AUTYPES.fetch(autype, 'unknown')}")
        trailer = 0
        hdr << case autype
               when 0 then field('authentication', off + 16, 8, hex(off + 16, 8), 'unused')
               when 1 then field('password', off + 16, 8, '********', 'simple password, hidden')
               when 2
                 trailer = u8(off + 19)
                 field('authentication', off + 16, 8, nil, "key #{u8(off + 18)}, seq #{u32(off + 20)}",
                       children: [num('reserved', off + 16, 2), num('key id', off + 18, 1),
                                  num('auth data length', off + 19, 1), num('crypto sequence', off + 20, 4)])
               else field('authentication', off + 16, 8, hex(off + 16, 8))
               end
        kids = [field('OSPF header', off, 24, nil, "#{name} from #{ip4(off + 4)}", children: hdr)]
        @errors << "OSPF length #{len} goes past the IP packet (#{ip_end - off})" if off + len > ip_end
        body = off + 24
        summary_extra = case type
                        when 1 then hello(kids, body, body_end)
                        when 2 then dd(kids, body, body_end)
                        when 3 then lsr(kids, body, body_end)
                        when 4 then lsu(kids, body, body_end)
                        when 5 then ack(kids, body, body_end)
                        else (kids << field('body', body, body_end - body, hex(body, body_end - body))) && ''
                        end
        if trailer.positive? && body_end < ip_end
          t = [trailer, ip_end - body_end].min
          kids << field('authentication data', body_end, t, hex(body_end, t), "#{t} bytes (digest)")
          body_end += t
        end
        kids << field('trailing data', body_end, ip_end - body_end, hex(body_end, ip_end - body_end), 'after the OSPF packet (LLS or padding)') if body_end < ip_end
        @summary = "#{name} #{src} > #{dst}#{summary_extra}"
        fields << field('OSPF', off, ip_end - off, nil, @summary, children: kids)
      end

      def hello(kids, off, stop)
        return (kids << truncated(off, stop)) && ' (truncated)' unless room?(off, 20, 'Hello') && off + 20 <= stop
        f = [field('network mask', off, 4, ip4(off), ip4(off)), num('hello interval', off + 4, 2, "#{u16(off + 4)} s"),
             options(off + 6), num('router priority', off + 7, 1), num('dead interval', off + 8, 4, "#{u32(off + 8)} s"),
             addr('designated router', off + 12), addr('backup designated router', off + 16)]
        nbrs = []
        o = off + 20
        while o + 4 <= stop
          nbrs << addr('neighbor', o)
          o += 4
        end
        f << field('neighbors', off + 20, o - off - 20, nbrs.size, nbrs.map(&:show).join(', '), children: nbrs) unless nbrs.empty?
        f << truncated(o, stop) if o < stop
        kids << field('Hello', off, stop - off, nil, "DR #{ip4(off + 12)}, #{nbrs.size} neighbors", children: f.compact)
        ", DR #{ip4(off + 12)}, #{nbrs.size} neighbors"
      end

      def dd(kids, off, stop)
        return (kids << truncated(off, stop)) && ' (truncated)' unless room?(off, 8, 'DD') && off + 8 <= stop
        flags = bits('flags', off + 3, 1, { 0x04 => 'I', 0x02 => 'M', 0x01 => 'MS' })
        f = [num('interface MTU', off, 2), options(off + 2), flags, num('DD sequence', off + 4, 4)]
        hdrs, o = lsa_headers(off + 8, stop)
        f << field('LSA headers', off + 8, o - off - 8, hdrs.size, "#{hdrs.size} LSA headers", children: hdrs) unless hdrs.empty?
        f << truncated(o, stop) if o < stop
        kids << field('Database Description', off, stop - off, nil, "#{flags.show} seq #{u32(off + 4)}", children: f.compact)
        " #{flags.show} seq #{u32(off + 4)}, #{hdrs.size} headers"
      end

      def lsr(kids, off, stop)
        reqs = []
        o = off
        while o + 12 <= stop
          t = u32(o)
          key = { type: t, ls_id: ip4(o + 4), advr: ip4(o + 8) }
          reqs << field('request', o, 12, nil, "#{LSA_TYPES.fetch(t, t)} #{key[:ls_id]} #{key[:advr]}", lsa: key,
                        children: [field('LS type', o, 4, t, "#{t} #{LSA_TYPES.fetch(t, '?')}"), addr('link state id', o + 4),
                                   addr('advertising router', o + 8)])
          o += 12
        end
        f = reqs
        f += [truncated(o, stop)] if o < stop
        kids << field('LS Request', off, stop - off, reqs.size, "#{reqs.size} requests", children: f.compact)
        ", #{reqs.size} requests"
      end

      def lsu(kids, off, stop)
        return (kids << truncated(off, stop)) && ' (truncated)' unless room?(off, 4, 'LS Update') && off + 4 <= stop
        count = u32(off)
        f = [num('number of LSAs', off, 4)]
        o = off + 4
        count.times do
          break if o + 20 > stop
          len = u16(o + 18)
          if len < 20 || o + len > stop
            @errors << "LSA at #{o} claims #{len} bytes, #{stop - o} left"
            break
          end
          f << lsa(o, len)
          o += len
        end
        @errors << "LS Update says #{count} LSAs, #{f.size - 1} found" if f.size - 1 != count
        f << truncated(o, stop) if o < stop
        kids << field('LS Update', off, stop - off, count, "#{count} LSAs", children: f.compact)
        ", #{count} LSAs"
      end

      def ack(kids, off, stop)
        hdrs, o = lsa_headers(off, stop)
        f = hdrs
        f += [truncated(o, stop)] if o < stop
        kids << field('LS Ack', off, stop - off, hdrs.size, "#{hdrs.size} LSA headers", children: f.compact)
        ", #{hdrs.size} headers"
      end

      def lsa_headers(off, stop)
        out = []
        o = off
        while o + 20 <= stop
          out << lsa_header(o, 'LSA header')
          o += 20
        end
        [out, o]
      end

      # ---- LSAs (RFC 2328 A.4)

      def key_of(off)
        seq = u32(off + 12)
        { type: u8(off + 3), ls_id: ip4(off + 4), advr: ip4(off + 8), seq: format('0x%08x', seq) }
      end

      def lsa_header_fields(off)
        type = u8(off + 3)
        ls_id = if [9, 10, 11].include?(type)
                  field('link state id', off + 4, 4, ip4(off + 4), "opaque type #{u8(off + 4)}, id #{u24(off + 5)}",
                        children: [num('opaque type', off + 4, 1), num('opaque id', off + 5, 3)])
                else
                  addr('link state id', off + 4)
                end
        [bits('LS age', off, 2, { 0x8000 => 'DoNotAge', 0x7fff => 'age' }, show_value: "#{u16(off) & 0x7fff} s"),
         options(off + 2), field('LS type', off + 3, 1, type, "#{type} #{LSA_TYPES.fetch(type, 'unknown')}"),
         ls_id, addr('advertising router', off + 8),
         field('sequence', off + 12, 4, u32(off + 12), format('0x%08x', u32(off + 12))),
         field('checksum', off + 16, 2, u16(off + 16), format('0x%04x', u16(off + 16))),
         num('length', off + 18, 2)]
      end

      def lsa_header(off, name)
        k = key_of(off)
        field(name, off, 20, nil, "#{LSA_TYPES.fetch(k[:type], k[:type])} #{k[:ls_id]} #{k[:advr]} #{k[:seq]}",
              lsa: k, children: lsa_header_fields(off))
      end

      def lsa(off, len)
        k = key_of(off)
        hdr = lsa_header_fields(off)
        ok = Core::Fletcher.valid?(@b.byteslice(off, len))
        @errors << "LSA #{LSA_TYPES.fetch(k[:type], k[:type])} #{k[:ls_id]} #{k[:advr]}: Fletcher checksum is wrong" unless ok
        hdr[6] = hdr[6].dup.tap { _1.check = { ok: ok } }
        body = off + 20
        stop = off + len
        b = case k[:type]
            when 1 then router_body(body, stop)
            when 2 then network_body(body, stop)
            when 3, 4 then summary_body(body, stop)
            when 5, 7 then external_body(body, stop)
            else [field('data', body, stop - body, hex(body, stop - body))]
            end.compact
        field("#{LSA_TYPES.fetch(k[:type], "type #{k[:type]}")} LSA", off, len,
              nil, "#{k[:ls_id]} #{k[:advr]} #{k[:seq]}", lsa: k,
              children: [field('LSA header', off, 20, nil, nil, children: hdr), *b])
      end

      def router_body(off, stop)
        return [truncated(off, stop)] if off + 4 > stop
        f = [bits('flags', off, 1, { 0x10 => 'Nt', 0x04 => 'V', 0x02 => 'E', 0x01 => 'B' }), num('reserved', off + 1, 1),
             num('number of links', off + 2, 2)]
        o = off + 4
        u16(off + 2).times do
          break if o + 12 > stop
          tos = u8(o + 9)
          t = u8(o + 8)
          lf = [addr('link id', o), addr('link data', o + 4), field('type', o + 8, 1, t, "#{t} #{LINK_TYPES.fetch(t, '?')}"),
                num('TOS count', o + 9, 1), num('metric', o + 10, 2)]
          tos.times do |i|
            p = o + 12 + i * 4
            break if p + 4 > stop
            lf << field('TOS metric', p, 4, nil, nil, children: [num('TOS', p, 1), num('reserved', p + 1, 1), num('metric', p + 2, 2)])
          end
          size = 12 + tos * 4
          f << field('link', o, [size, stop - o].min, nil, "#{LINK_TYPES.fetch(t, t)} #{ip4(o)} metric #{u16(o + 10)}", children: lf)
          o += size
        end
        f << truncated(o, stop) if o < stop
        f
      end

      def network_body(off, stop)
        return [truncated(off, stop)] if off + 4 > stop
        f = [field('network mask', off, 4, ip4(off), ip4(off))]
        o = off + 4
        while o + 4 <= stop
          f << addr('attached router', o)
          o += 4
        end
        f << truncated(o, stop) if o < stop
        f
      end

      def summary_body(off, stop)
        return [truncated(off, stop)] if off + 8 > stop
        f = [field('network mask', off, 4, ip4(off), ip4(off)), num('reserved', off + 4, 1), num('metric', off + 5, 3)]
        o = off + 8
        while o + 4 <= stop
          f << field('TOS metric', o, 4, nil, nil, children: [num('TOS', o, 1), num('metric', o + 1, 3)])
          o += 4
        end
        f << truncated(o, stop) if o < stop
        f
      end

      def external_body(off, stop)
        return [truncated(off, stop)] if off + 16 > stop
        f = [field('network mask', off, 4, ip4(off), ip4(off))]
        o = off + 4
        first = true
        while o + 12 <= stop
          e = u8(o)
          ext = [field('E', o, 1, e >> 7, (e >> 7).positive? ? 'type 2' : 'type 1', mask: 0x80),
                 field('TOS', o, 1, e & 0x7f, nil, mask: 0x7f), num('metric', o + 1, 3),
                 addr('forwarding address', o + 4), num('route tag', o + 8, 4)]
          f << field(first ? 'external route' : 'TOS route', o, 12, nil,
                     "E#{(e >> 7).positive? ? 2 : 1} metric #{u24(o + 1)}", children: ext)
          first = false
          o += 12
        end
        f << truncated(o, stop) if o < stop
        f
      end
    end
  end
end
