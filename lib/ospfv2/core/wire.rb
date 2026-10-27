# frozen_string_literal: true

require_relative 'lsa'

module OSPFv2
  module Core
    # OSPFv2 packets on the wire (RFC 2328 A.3).
    #
    # Decoding is strict: anything malformed raises Wire::Error with a
    # reason, which the interface counts and logs. LSAs inside updates stay
    # as raw bytes (Core::Lsa), so they are flooded unchanged.
    #
    #   bytes = Wire.encode(Wire::Hello.new(...), router_id: rid, area_id: 0)
    #   pkt   = Wire.decode(bytes)          # => Wire::Packet
    #   pkt.body                            # => Wire::Hello
    module Wire
      class Error < StandardError; end

      VERSION = 2
      HEADER_SIZE = 24
      IP_HEADER_SIZE = 20

      HELLO = 1
      DD    = 2
      LSR   = 3
      LSU   = 4
      ACK   = 5

      NAMES = { HELLO => :hello, DD => :dd, LSR => :ls_request, LSU => :ls_update, ACK => :ls_ack }.freeze

      Packet = Struct.new(:type, :router_id, :area_id, :autype, :auth, :body, keyword_init: true) do
        def name = NAMES[type]
      end

      Hello = Struct.new(:netmask, :hello_interval, :options, :priority, :dead_interval,
                         :dr, :bdr, :neighbors, keyword_init: true) do
        def self.type = HELLO

        def encode
          [netmask, hello_interval, options, priority, dead_interval, dr, bdr, *neighbors].pack('NnCCNNNN*')
        end

        def self.decode(b)
          raise Error, "hello too short (#{b.bytesize})" if b.bytesize < 20
          raise Error, 'hello neighbor list not a multiple of 4' unless ((b.bytesize - 20) % 4).zero?
          mask, hi, opt, pri, dead, dr, bdr, *nbrs = b.unpack('NnCCNNNN*')
          new(netmask: mask, hello_interval: hi, options: opt, priority: pri, dead_interval: dead,
              dr: dr, bdr: bdr, neighbors: nbrs)
        end
      end

      # DD flags
      DD_INIT   = 4
      DD_MORE   = 2
      DD_MASTER = 1

      DatabaseDescription = Struct.new(:mtu, :options, :flags, :seq, :headers, keyword_init: true) do
        def self.type = DD
        def init? = (flags & DD_INIT).positive?
        def more? = (flags & DD_MORE).positive?
        def master? = (flags & DD_MASTER).positive?

        def encode
          [mtu, options, flags, seq].pack('nCCN') + headers.map(&:encode_header).join
        end

        def self.decode(b)
          raise Error, "DD too short (#{b.bytesize})" if b.bytesize < 8
          raise Error, 'DD headers not a multiple of 20' unless ((b.bytesize - 8) % 20).zero?
          mtu, opt, flags, seq = b.unpack('nCCN')
          headers = (8...b.bytesize).step(20).map { |o| LsaHeader.parse(b.byteslice(o, 20)) }
          new(mtu: mtu, options: opt, flags: flags & 7, seq: seq, headers: headers)
        end

        def flag_string
          [init? ? 'I' : nil, more? ? 'M' : nil, master? ? 'MS' : nil].compact.join('|')
        end
      end

      LinkStateRequest = Struct.new(:requests, keyword_init: true) do
        def self.type = LSR

        def encode
          requests.map { |t, id, advr| [t, id, advr].pack('NNN') }.join
        end

        def self.decode(b)
          raise Error, 'LS request not a multiple of 12' unless (b.bytesize % 12).zero?
          new(requests: b.unpack('N*').each_slice(3).to_a)
        end
      end

      LinkStateUpdate = Struct.new(:lsas, keyword_init: true) do
        def self.type = LSU

        def encode
          [lsas.size].pack('N') + lsas.map(&:bytes).join
        end

        def self.decode(b)
          raise Error, "LS update too short (#{b.bytesize})" if b.bytesize < 4
          count = b.unpack1('N')
          # The count comes off the wire: never let it size an allocation.
          max = (b.bytesize - 4) / LsaHeader::SIZE
          raise Error, "LS update claims #{count} LSAs, room for at most #{max}" if count > max
          off = 4
          lsas = Array.new(count) do
            lsa = Lsa.parse(b.byteslice(off..))
            off += lsa.length
            lsa
          rescue Lsa::Error => e
            raise Error, "LS update: #{e.message}"
          end
          new(lsas: lsas)
        end
      end

      LinkStateAck = Struct.new(:headers, keyword_init: true) do
        def self.type = ACK

        def encode
          headers.map(&:encode_header).join
        end

        def self.decode(b)
          raise Error, 'LS ack not a multiple of 20' unless (b.bytesize % 20).zero?
          new(headers: (0...b.bytesize).step(20).map { |o| LsaHeader.parse(b.byteslice(o, 20)) })
        end
      end

      BODIES = { HELLO => Hello, DD => DatabaseDescription, LSR => LinkStateRequest,
                 LSU => LinkStateUpdate, ACK => LinkStateAck }.freeze

      module_function

      # Builds a packet with null authentication (AuType 0).
      def encode(body, router_id:, area_id:)
        payload = body.encode
        hdr = [VERSION, body.class.type, HEADER_SIZE + payload.bytesize, router_id, area_id, 0, 0, 0, 0]
              .pack('CCnNNnnNN')
        raw = (hdr + payload).b
        raw[12, 2] = [inet_checksum(raw)].pack('n')
        raw
      end

      # Parses and checks one packet (RFC 2328 8.2, minus the interface
      # checks the caller does). Trailing bytes after the OSPF length, such
      # as a Cisco LLS block, are ignored.
      def decode(bytes)
        raise Error, "packet too short (#{bytes.bytesize})" if bytes.bytesize < HEADER_SIZE
        ver, type, len, rid, aid, csum, autype, auth = bytes.unpack('CCnNNnna8')
        raise Error, "version #{ver}, expected 2" unless ver == VERSION
        raise Error, "length #{len} out of range (#{bytes.bytesize} received)" if len < HEADER_SIZE || len > bytes.bytesize
        body_class = BODIES[type] or raise Error, "unknown packet type #{type}"
        raw = bytes.byteslice(0, len)
        case autype
        when 0
          raise Error, format('bad checksum 0x%04x', csum) unless inet_checksum(raw).zero?
        else
          raise Error, "authentication type #{autype} not supported"
        end
        Packet.new(type: type, router_id: rid, area_id: aid, autype: autype, auth: auth,
                   body: body_class.decode(raw.byteslice(HEADER_SIZE..)))
      end

      # RFC 1071 one's complement sum. The 8 authentication bytes are not
      # covered (RFC 2328 D.4.1); with AuType 0 they are zero anyway.
      def inet_checksum(raw)
        data = raw.dup
        data[16, 8] = "\0" * 8
        data << "\0" if data.bytesize.odd?
        sum = data.unpack('n*').sum
        sum = (sum & 0xffff) + (sum >> 16) while sum > 0xffff
        ~sum & 0xffff
      end

      # Largest OSPF body that fits an interface MTU.
      def max_body(mtu)
        mtu - IP_HEADER_SIZE - HEADER_SIZE
      end

      # Splits +items+ into groups whose encoded size fits +room+ bytes.
      # +fixed+ is the per-packet overhead inside the body.
      def batches(items, room, fixed: 0)
        out = [[]]
        used = fixed
        items.each do |it|
          size = yield(it)
          if used + size > room && !out.last.empty?
            out << []
            used = fixed
          end
          out.last << it
          used += size
        end
        out.reject(&:empty?)
      end
    end
  end
end
