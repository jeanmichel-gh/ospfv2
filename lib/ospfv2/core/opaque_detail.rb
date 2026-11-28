# frozen_string_literal: true

require_relative 'router_information'
require_relative 'extended'

module OSPFv2
  module Core
    # show.database's detail for an opaque LSA (docs/design/sr-ospf.md,
    # "Answers for routescope", answer 2): each TLV and sub-TLV with its
    # `type` and `name` (the registry name with hyphens, as the
    # dissector's key), flags as the RFC's letters, a SID as `index` (V
    # and L clear) or `label` (both set). An invalid pair gives `value`
    # and `finding`. An unknown TLV, or an opaque type not decoded, gives
    # `type` and `hex`. The codec's own to_hash is for building; this is
    # for reading.
    module OpaqueDetail
      RI = RouterInformation
      XP = ExtendedPrefix
      XL = ExtendedLink

      # RFC 7770 section 2.4: bits numbered from the left, bit 0 first.
      CAPABILITIES = %w[graceful-restart-capable graceful-restart-helper stub-router traffic-engineering
                        p2p-over-lan experimental-te].freeze
      PREFIX_FLAGS = { 0x80 => 'A', 0x40 => 'N' }.freeze # RFC 7684 section 2.1
      PREFIX_SID_FLAGS = { 0x40 => 'NP', 0x20 => 'M', 0x10 => 'E', 0x08 => 'V', 0x04 => 'L' }.freeze # RFC 8665 5
      ADJ_SID_FLAGS = { 0x80 => 'B', 0x40 => 'V', 0x20 => 'L', 0x10 => 'G', 0x08 => 'P' }.freeze # RFC 8665 6.1
      LINK_TYPES = { 1 => 'p2p', 2 => 'transit', 3 => 'stub', 4 => 'virtual' }.freeze # RFC 2328 A.4.2

      BODIES = { RI::OPAQUE_TYPE => RI::Body, XP::OPAQUE_TYPE => XP::Body, XL::OPAQUE_TYPE => XL::Body }.freeze

      module_function

      # +opaque_type+ and +body+ (octets) of one LSA.
      def of(opaque_type, body)
        klass = BODIES[opaque_type] or return { hex: body.unpack1('H*') }
        { tlvs: klass.new(body).tlvs.map { tlv(_1) } }
      end

      def flags(bits, names) = names.filter_map { |bit, n| n if bits.anybits?(bit) }

      def tlv(t)
        case t
        when RI::Capabilities
          bits = (0..31).select { t.bits.anybits?(1 << (31 - _1)) }
          { type: 1, name: 'informational-capabilities', bits: bits.map { CAPABILITIES[_1] || "bit-#{_1}" } }
        when RI::SrAlgorithm then { type: 8, name: 'sr-algorithm', algorithms: t.algorithms }
        when RI::SidLabelRange, RI::Srlb then range(t)
        when XP::Prefix
          { type: 1, name: 'extended-prefix', route_type: t.route_type, prefix: t.prefix_s, af: t.af,
            flags: flags(t.flags, PREFIX_FLAGS), sub_tlvs: t.subs.map { sub(_1) } }
        when XL::Link
          { type: 1, name: 'extended-link', link_type: LINK_TYPES.fetch(t.link_type, t.link_type),
            link_id: Addr.to_s(t.link_id), link_data: Addr.to_s(t.link_data), sub_tlvs: t.subs.map { sub(_1) } }
        else unknown(t)
        end
      end

      def sub(t)
        case t
        when XP::PrefixSid
          { type: 2, name: 'prefix-sid', flags: flags(t.flags, PREFIX_SID_FLAGS), mt_id: t.mt_id, algorithm: t.algorithm }
            .merge(sid(t, XP::PrefixSid::V, XP::PrefixSid::L, :prefix_sid_vl_invalid))
        when XL::LanAdjSid
          { type: 3, name: 'lan-adj-sid', flags: flags(t.flags, ADJ_SID_FLAGS), mt_id: t.mt_id, weight: t.weight,
            neighbor: Addr.to_s(t.neighbor) }.merge(sid(t, XL::AdjSid::V, XL::AdjSid::L, :adj_sid_vl_invalid))
        when XL::AdjSid
          { type: 2, name: 'adj-sid', flags: flags(t.flags, ADJ_SID_FLAGS), mt_id: t.mt_id, weight: t.weight }
            .merge(sid(t, XL::AdjSid::V, XL::AdjSid::L, :adj_sid_vl_invalid))
        when RI::SidLabel then { type: 1, name: 'sid-label' }.merge(t.label? ? { label: t.sid } : { sid: t.sid })
        else unknown(t)
        end
      end

      # RFC 8665 section 5: V and L clear, an index; both set, a label.
      def sid(t, v_bit, l_bit, finding)
        v = t.flags.anybits?(v_bit)
        l = t.flags.anybits?(l_bit)
        return { index: t.sid } if !v && !l
        return { label: t.sid } if v && l
        { value: t.sid, finding: finding.to_s }
      end

      # RFC 8665 sections 3.2, 3.3: the size and the first label, or SID.
      def range(t)
        name = t.is_a?(RI::Srlb) ? 'srlb' : 'sid-label-range'
        first = t.subs.grep(RI::SidLabel).first
        d = { type: t.type, name: name, size: t.size }
        d.merge!(first.label? ? { label: first.sid } : { sid: first.sid }) if first
        d[:finding] = 'range_two_sid_labels' if t.sid_labels > 1
        others = t.subs.reject { _1.is_a?(RI::SidLabel) }
        others.empty? ? d : d.merge(sub_tlvs: others.map { sub(_1) })
      end

      def unknown(t) = { type: t.type, hex: t.is_a?(Tlv::Unknown) ? t.value.unpack1('H*') : t.to_shex }
    end
  end
end
