# frozen_string_literal: true

require_relative 'tlv'
require_relative 'addr'

module OSPFv2
  module Core
    # A SID sub-TLV's SID (RFC 8665 sections 5, 6.1, 6.2): a 3-octet label
    # when the V flag is set, else a 4-octet index. A parsed one keeps the
    # size it came in; +octets+ overrides it, for a SID wrong on purpose.
    module SidField
      attr_reader :flags, :mt_id, :sid

      def label? = @flags.anybits?(self.class::V)

      private

      def sid_octets = @octets || (label? ? 3 : 4)

      def encode_sid = sid_octets == 3 ? Tlv.three(@sid) : [@sid].pack('N')

      def decode_sid(v)
        @octets = v.bytesize
        @sid = @octets == 3 ? Tlv.from_three(v) : v.byteslice(0, 4).ljust(4, "\0").unpack1('N')
      end

      def set_sid(f)
        @flags = Integer(f.fetch(:flags, 0))
        @mt_id = Integer(f.fetch(:mt_id, 0))
        @sid = Integer(f.fetch(:sid))
        @octets = f[:octets] && Integer(f[:octets])
      end

      def sid_fields = { flags: @flags, mt_id: @mt_id, sid: @sid }.merge(@octets ? { octets: @octets } : {})
    end

    # The extended prefix opaque LSA (RFC 7684 section 2): opaque type 7.
    module ExtendedPrefix
      OPAQUE_TYPE = 7
      A_FLAG = 0x80
      N_FLAG = 0x40

      # Prefix-SID (RFC 8665 section 5): flags (NP 0x40, M 0x20, E 0x10,
      # V 0x08, L 0x04), reserved, MT-ID, algorithm, the SID.
      class PrefixSid < Tlv
        include SidField
        TYPE = 2
        NP = 0x40
        M = 0x20
        E = 0x10
        V = 0x08
        L = 0x04
        attr_reader :algorithm

        def fields = sid_fields.merge(algorithm: @algorithm)
        def to_s = "prefix-sid #{label? ? 'label' : 'index'} #{@sid} algorithm #{@algorithm} flags 0x#{@flags.to_s(16)}"

        private

        def set(f)
          set_sid(f)
          @algorithm = Integer(f.fetch(:algorithm, 0))
        end

        def value = [@flags, 0, @mt_id, @algorithm].pack('C4') + encode_sid

        def decode(v)
          raise Error, "Prefix-SID of #{v.bytesize} octets" if v.bytesize < 5
          @flags, _, @mt_id, @algorithm = v.unpack('C4')
          decode_sid(v.byteslice(4..))
        end
      end

      SUB_TLVS = { 2 => PrefixSid }.freeze

      # The Extended Prefix TLV (RFC 7684 section 2.1).
      class Prefix < Tlv
        TYPE = 1
        attr_reader :route_type, :prefix_len, :af, :flags, :prefix, :subs

        def prefix_s = "#{Addr.to_s(@prefix)}/#{@prefix_len}"
        def sids = @subs.grep(PrefixSid)
        def fields = { route_type: @route_type, prefix: prefix_s, af: @af, flags: @flags, subs: @subs.map(&:to_hash) }
        def to_s = (["prefix #{prefix_s} route-type #{@route_type} flags 0x#{@flags.to_s(16)}"] + @subs.map(&:to_s)).join("\n")

        private

        def set(f)
          @route_type = Integer(f.fetch(:route_type, 1))
          ip, len = f.fetch(:prefix).to_s.split('/')
          @prefix = Addr.to_i(ip)
          @prefix_len = Integer(len || f.fetch(:prefix_len))
          @af = Integer(f.fetch(:af, 0))
          @flags = Integer(f.fetch(:flags, 0))
          @subs = Array(f[:subs]).map { _1.is_a?(Tlv) ? _1 : Tlv.from_hash(_1, SUB_TLVS) }
        end

        # The prefix in 4 octets: IPv4 (RFC 7684 section 2.1, AF 0).
        def value = [@route_type, @prefix_len, @af, @flags, @prefix].pack('C4N') + @subs.map(&:encode).join

        def decode(v)
          raise Error, "Extended Prefix TLV of #{v.bytesize} octets, less than 8" if v.bytesize < 8
          @route_type, @prefix_len, @af, @flags, @prefix = v.unpack('C4N')
          @subs = Tlv.list(v.byteslice(8..), SUB_TLVS)
        end
      end

      TLVS = { 1 => Prefix }.freeze

      class Body < Tlv::Body
        TLVS = ExtendedPrefix::TLVS

        def prefixes = @tlvs.grep(Prefix)
      end
    end

    # The extended link opaque LSA (RFC 7684 section 3): opaque type 8.
    module ExtendedLink
      OPAQUE_TYPE = 8

      # Adj-SID (RFC 8665 section 6.1): flags (B 0x80, V 0x40, L 0x20, G
      # 0x10, P 0x08), reserved, MT-ID, weight, the SID.
      class AdjSid < Tlv
        include SidField
        TYPE = 2
        B = 0x80
        V = 0x40
        L = 0x20
        G = 0x10
        P = 0x08
        attr_reader :weight

        def backup? = @flags.anybits?(B)
        def fields = sid_fields.merge(weight: @weight)
        def to_s = "adj-sid #{@sid} weight #{@weight} flags 0x#{@flags.to_s(16)}"

        private

        def set(f)
          set_sid(f)
          @weight = Integer(f.fetch(:weight, 0))
        end

        def value = [@flags, 0, @mt_id, @weight].pack('C4') + encode_sid

        def decode(v)
          raise Error, "Adj-SID of #{v.bytesize} octets" if v.bytesize < 5
          @flags, _, @mt_id, @weight = v.unpack('C4')
          decode_sid(v.byteslice(4..))
        end
      end

      # LAN Adj-SID (6.2): the neighbor's router ID before the SID.
      class LanAdjSid < AdjSid
        TYPE = 3
        attr_reader :neighbor

        def fields = super.merge(neighbor: Addr.to_s(@neighbor))
        def to_s = "lan-adj-sid #{@sid} neighbor #{Addr.to_s(@neighbor)} weight #{@weight} flags 0x#{@flags.to_s(16)}"

        private

        def set(f)
          super
          @neighbor = Addr.to_i(f.fetch(:neighbor))
        end

        def value = [@flags, 0, @mt_id, @weight, @neighbor].pack('C4N') + encode_sid

        def decode(v)
          raise Error, "LAN Adj-SID of #{v.bytesize} octets" if v.bytesize < 9
          @flags, _, @mt_id, @weight, @neighbor = v.unpack('C4N')
          decode_sid(v.byteslice(8..))
        end
      end

      SUB_TLVS = { 2 => AdjSid, 3 => LanAdjSid }.freeze

      # The Extended Link TLV (RFC 7684 section 3.1): a link of the
      # router-LSA (RFC 2328 A.4.2: 1 p2p, 2 transit, 3 stub, 4 virtual).
      class Link < Tlv
        TYPE = 1
        attr_reader :link_type, :link_id, :link_data, :subs

        def adj_sids = @subs.grep(AdjSid).reject { _1.is_a?(LanAdjSid) }
        def lan_adj_sids = @subs.grep(LanAdjSid)
        def key = [@link_type, @link_id, @link_data]
        def fields = { link_type: @link_type, link_id: Addr.to_s(@link_id), link_data: Addr.to_s(@link_data),
                       subs: @subs.map(&:to_hash) }
        def to_s = (["link type #{@link_type} id #{Addr.to_s(@link_id)} data #{Addr.to_s(@link_data)}"] +
                    @subs.map(&:to_s)).join("\n")

        private

        def set(f)
          @link_type = Integer(f.fetch(:link_type))
          @link_id = Addr.to_i(f.fetch(:link_id))
          @link_data = Addr.to_i(f.fetch(:link_data))
          @subs = Array(f[:subs]).map { _1.is_a?(Tlv) ? _1 : Tlv.from_hash(_1, SUB_TLVS) }
        end

        def value = [@link_type, 0, 0, 0, @link_id, @link_data].pack('C4NN') + @subs.map(&:encode).join

        def decode(v)
          raise Error, "Extended Link TLV of #{v.bytesize} octets, less than 12" if v.bytesize < 12
          @link_type, _, _, _, @link_id, @link_data = v.unpack('C4NN')
          @subs = Tlv.list(v.byteslice(12..), SUB_TLVS)
        end
      end

      TLVS = { 1 => Link }.freeze

      class Body < Tlv::Body
        TLVS = ExtendedLink::TLVS

        def links = @tlvs.grep(Link)
      end
    end
  end
end
