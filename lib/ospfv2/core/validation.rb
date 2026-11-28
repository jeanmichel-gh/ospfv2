# frozen_string_literal: true

require_relative 'addr'

module OSPFv2
  # What ospfd finds wrong in what it receives, each with the RFC text
  # that says so and what the RFC asks for (docs/design/sr-ospf.md, step
  # 0; routescope docs/design/protocol-conventions.md, item 3).
  #
  # Validation decides nothing. It names a finding and the action each
  # receive policy takes; the caller acts. Building never validates: the
  # fault catalog (OSPFv2::Fault) makes wrong values on purpose.
  #
  # The policies:
  #   :rfc      what the RFC asks for, the default.
  #   :strict   refuses more: a router or an LSA rather than one TLV.
  #   :lenient  uses what it can. Where using a value is impossible, it
  #             does what :rfc does, and the rule says why.
  #
  # The actions:
  #   :drop_lsa      the LSA is discarded and not acknowledged.
  #   :seq_mismatch  the DD exchange starts again (RFC 2328 10.8).
  #   :ignore_lsa    the LSA is left out of SR; it is still held.
  #   :ignore_tlv    that TLV is left out.
  #   :ignore_sid    that SID is left out.
  #   :ignore_range  that SID/Label Range or SRLB is left out.
  #   :ignore_router the router is left out of SR.
  #   :use_first     the first of several is used, the rest ignored.
  #   :use           the value is used as it is.
  module Validation
    POLICIES = %i[rfc strict lenient].freeze
    # :rfc2328 rules are the receive path's checks on packets this spec
    # touches; :opaque and :sr rules each have an entry in OSPFv2::Fault.
    # :labels rules are found by the label calculation (Core::SrLabels),
    # across LSAs, so no one LSA of the catalog makes them.
    GROUPS = %i[rfc2328 opaque sr labels].freeze

    Rule = Struct.new(:name, :group, :clause, :description, :actions, keyword_init: true)

    Finding = Struct.new(:name, :group, :clause, :subject, :detail) do
      def to_s = "#{subject}: #{detail} (#{clause})"

      def to_hash = { name: name.to_s, group: group.to_s, clause: clause, subject: subject, detail: detail }
    end

    # The same action under every policy.
    def self.always(action) = POLICIES.to_h { [_1, action] }

    RULES = [
      # ---- RFC 2328, the drops in receive_update and accept_dd
      # Nothing can be stored where the area has no database for it, so
      # every policy drops.
      Rule.new(name: :as_external_in_stub, group: :rfc2328,
               clause: 'RFC 2328 section 13 (3): "if this is an AS-external-LSA (LS type = 5), and the area has been ' \
                       'configured as a stub area, discard the LSA"',
               description: 'an AS-external LSA received in a stub area or an NSSA',
               actions: always(:drop_lsa)),
      Rule.new(name: :as_external_over_virtual_link, group: :rfc2328,
               clause: 'RFC 2328 section 15: "AS-external-LSAs are NEVER flooded over virtual adjacencies"',
               description: 'an AS-external LSA received over a virtual link',
               actions: always(:drop_lsa)),
      Rule.new(name: :nssa_outside_nssa, group: :rfc2328,
               clause: 'RFC 3101 section 2.3: "Type-7 LSAs are only flooded within the originating NSSA"',
               description: 'a type 7 LSA received outside an NSSA',
               actions: always(:drop_lsa)),
      Rule.new(name: :unsupported_lsa_type, group: :rfc2328,
               clause: 'RFC 2328 section 13 (2): "If the LS type is unknown, discard the LSA"',
               description: 'an LSA of a type ospfd has no database for',
               actions: always(:drop_lsa)),
      Rule.new(name: :dd_unsupported_type, group: :rfc2328,
               clause: 'RFC 2328 section 10.6: "If the LS type is unknown ... generate the neighbor event ' \
                       'SeqNumberMismatch"',
               description: 'a DD that offers an LSA of a type ospfd has no database for',
               actions: always(:seq_mismatch)),
      Rule.new(name: :dd_as_external_in_stub, group: :rfc2328,
               clause: 'RFC 2328 section 10.6: "if this is an AS-external-LSA (LS type = 5) and the neighbor is ' \
                       'associated with a stub area, generate the neighbor event SeqNumberMismatch"',
               description: 'a DD that offers an AS-external LSA in a stub area or an NSSA',
               actions: always(:seq_mismatch)),
      Rule.new(name: :dd_nssa_outside_nssa, group: :rfc2328,
               clause: 'RFC 3101 section 2.3: "Type-7 LSAs are only flooded within the originating NSSA"',
               description: 'a DD that offers a type 7 LSA outside an NSSA',
               actions: always(:seq_mismatch)),

      # A DD carries headers, not an LSA, so this one has no catalog entry;
      # its text is RFC 5250's.
      Rule.new(name: :dd_opaque_as_in_stub, group: :rfc2328,
               clause: 'RFC 5250 section 3: "if a type-11 Opaque LSA is received in a stub area or NSSA from a ' \
                       'neighboring router within the stub area or NSSA, the LSA is rejected"',
               description: 'a DD that offers a type 11 opaque LSA in a stub area or an NSSA',
               actions: always(:seq_mismatch)),

      # ---- Opaque LSAs (RFC 5250)
      Rule.new(name: :opaque_as_in_stub, group: :opaque,
               clause: 'RFC 5250 section 3.1: "A type-11 Opaque LSA that is received on an interface associated ' \
                       'with a stub area or NSSA MUST be discarded and not acknowledged"',
               description: 'a type 11 opaque LSA received in a stub area or an NSSA',
               actions: always(:drop_lsa)),

      # ---- The extended LSAs (RFC 7684)
      Rule.new(name: :prefix_tlv_twice, group: :opaque,
               clause: 'RFC 7684 section 2.1: "If this TLV is advertised multiple times for the same prefix in the ' \
                       'same OSPFv2 Extended Prefix Opaque LSA, only the first instance of the TLV is used"',
               description: 'an extended prefix LSA with two Extended Prefix TLVs for one prefix',
               actions: { rfc: :use_first, strict: :ignore_lsa, lenient: :use_first }),
      Rule.new(name: :link_tlv_twice, group: :opaque,
               clause: 'RFC 7684 section 3.1: "Only one OSPFv2 Extended Link TLV SHALL be advertised in each OSPFv2 ' \
                       'Extended Link Opaque LSA"; with several, "only the first instance of the TLV is used"',
               description: 'an extended link LSA with two Extended Link TLVs',
               actions: { rfc: :use_first, strict: :ignore_lsa, lenient: :use_first }),

      # ---- SR (RFC 8665), on the RI and extended LSAs
      Rule.new(name: :sr_algorithm_twice, group: :sr,
               clause: 'RFC 8665 section 3.1: "When multiple SR-Algorithm TLVs are received from a given router, ' \
                       'the receiver MUST use the first occurrence of the TLV"',
               description: 'a Router Information LSA with two SR-Algorithm TLVs',
               actions: { rfc: :use_first, strict: :ignore_router, lenient: :use_first }),
      # A range of nothing holds no label, so lenient cannot use it.
      Rule.new(name: :sid_label_range_zero, group: :sr,
               clause: 'RFC 8665 section 3.2: the SID/Label Range size "MUST be greater than 0"',
               description: 'a SID/Label Range TLV with a range size of 0',
               actions: { rfc: :ignore_range, strict: :ignore_router, lenient: :ignore_range }),
      Rule.new(name: :srlb_range_zero, group: :sr,
               clause: 'RFC 8665 section 3.3: the SRLB range size "MUST be greater than 0"',
               description: 'an SR Local Block TLV with a range size of 0',
               actions: { rfc: :ignore_range, strict: :ignore_router, lenient: :ignore_range }),
      # Which first label to take cannot be told, so no policy uses it.
      Rule.new(name: :range_two_sid_labels, group: :sr,
               clause: 'RFC 8665 section 3.2: "If more than one SID/Label Sub-TLV is present, the SID/Label Range ' \
                       'TLV MUST be ignored"; section 3.3, the same for the SRLB TLV',
               description: 'a SID/Label Range or SRLB TLV with two SID/Label sub-TLVs',
               actions: always(:ignore_range)),
      # Which of index and label it is cannot be told, so lenient ignores it too.
      Rule.new(name: :prefix_sid_vl_invalid, group: :sr,
               clause: 'RFC 8665 section 5: "any SID Advertisement received with an invalid setting for V- and ' \
                       'L-Flags MUST be ignored"',
               description: 'a Prefix-SID with V set and L clear, or L set and V clear',
               actions: always(:ignore_sid)),
      # RFC 8665 section 6.1 gives the Adj-SID's SID "As described in
      # Section 5", so section 5's rule holds for it too.
      Rule.new(name: :adj_sid_vl_invalid, group: :sr,
               clause: 'RFC 8665 section 6.1: the SID "As described in Section 5"; section 5: "any SID ' \
                       'Advertisement received with an invalid setting for V- and L-Flags MUST be ignored"',
               description: 'an Adj-SID or LAN Adj-SID with V set and L clear, or L set and V clear',
               actions: always(:ignore_sid)),
      Rule.new(name: :prefix_sid_multiple, group: :sr,
               clause: 'RFC 8665 section 5: "If an OSPF router advertises multiple Prefix-SIDs for the same prefix, ' \
                       'topology, and algorithm, all of them MUST be ignored"',
               description: 'an Extended Prefix TLV with two Prefix-SIDs for one MT-ID and algorithm',
               actions: always(:ignore_sid)),

      # ---- The label calculation (Core::SrLabels)
      Rule.new(name: :prefix_sid_algorithm, group: :labels,
               clause: 'RFC 8665 section 5: a Prefix-SID "with an algorithm value that the remote node has not ' \
                       'advertised in the SR-Algorithm TLV (Section 3.1) MUST" be ignored',
               description: 'a Prefix-SID for an algorithm its router does not advertise',
               actions: always(:ignore_sid)),
      # Open question 2: drop both, as isisd does, or RFC 8660 2.5.1's
      # tie-breaking. Both are dropped until the owner decides.
      Rule.new(name: :prefix_sid_duplicate, group: :labels,
               clause: 'RFC 8660 section 2.5: "An implementation MUST NOT allow the MCCs belonging to the same router ' \
                       'to assign the same incoming label to more than one SR FEC"',
               description: 'one index on two prefixes',
               actions: always(:drop_both)),
      # The rest of the LSA cannot be read, so no policy uses it.
      Rule.new(name: :tlv_overrun, group: :sr,
               clause: 'RFC 8665 section 9: "if the length is invalid, the LSA in which it is advertised is ' \
                       'considered malformed and MUST be ignored"; RFC 7684 section 5: "Malformed LSAs MUST NOT be ' \
                       'stored in the Link State Database (LSDB), acknowledged, or reflooded"',
               description: 'a TLV or sub-TLV whose length runs past the TLV, or the LSA, that holds it',
               actions: always(:drop_lsa))
    ].to_h { [_1.name, _1] }.freeze

    OPAQUE_RI = 4
    OPAQUE_EXT_PREFIX = 7
    OPAQUE_EXT_LINK = 8

    module_function

    def rule(name)
      RULES.fetch(name.to_sym) { raise ArgumentError, "no rule #{name.inspect}; the rules are #{RULES.keys.join(', ')}" }
    end

    def policy(name)
      p = (name || :rfc).to_sym
      raise ArgumentError, "receive_policy is #{POLICIES.join(', ')}, not #{name}" unless POLICIES.include?(p)
      p
    end

    def finding(name, subject, detail)
      r = rule(name)
      Finding.new(r.name, r.group, r.clause, subject, detail)
    end

    def action(finding, policy) = rule(finding.name).actions.fetch(policy(policy))

    # ---- opaque LSA bodies

    # The findings in an opaque LSA's body (after its 20-octet header).
    # +opaque_type+ is the link state ID's first octet (RFC 5250 section
    # 3). Types other than RI, extended prefix and extended link give
    # none. It never raises: an overrun is a finding, and the walk stops.
    def opaque(opaque_type, body, subject)
      case opaque_type
      when OPAQUE_RI then router_information(body, subject)
      when OPAQUE_EXT_PREFIX
        found = extended(body, subject, 1, 8) { |sub| prefix_sid(sub, subject) }
        found + twice(body, subject, :prefix_tlv_twice) { |v| v.byteslice(1, 1) + v.byteslice(4, 4).to_s } +
          multiple_sids(body, subject)
      when OPAQUE_EXT_LINK
        extended(body, subject, 1, 12) { |sub| adj_sid(sub, subject) } +
          twice(body, subject, :link_tlv_twice) { |_| :link }
      else []
      end
    end

    # TLVs as [type, value] pairs, each padded to 4 octets (RFC 7770
    # section 2.3, RFC 7684 section 2). Returns [tlvs, overrun], where
    # overrun is the detail of a TLV past the end, or nil.
    def tlvs(octets)
      out = []
      at = 0
      while at < octets.bytesize
        return [out, "#{octets.bytesize - at} octets left, less than a TLV header"] if octets.bytesize - at < 4
        type, len = octets.byteslice(at, 4).unpack('nn')
        return [out, "TLV #{type} of length #{len} runs past its end, #{octets.bytesize - at - 4} octets left"] if at + 4 + len > octets.bytesize
        out << [type, octets.byteslice(at + 4, len)]
        at += 4 + ((len + 3) & ~3)
      end
      [out, nil]
    end

    def overrun(detail, subject) = [finding(:tlv_overrun, subject, detail)]

    # RFC 8665 section 3: SR-Algorithm (8), SID/Label Range (9) and SRLB (14).
    def router_information(body, subject)
      list, bad = tlvs(body)
      return overrun(bad, subject) if bad
      found = []
      algorithms = list.count { _1[0] == 8 }
      found << finding(:sr_algorithm_twice, subject, "#{algorithms} SR-Algorithm TLVs") if algorithms > 1
      list.each do |type, value|
        next unless [9, 14].include?(type)
        return overrun("TLV #{type} of length #{value.bytesize}, less than its 4-octet range", subject) if value.bytesize < 4
        subs, bad = tlvs(value.byteslice(4..))
        return overrun("in TLV #{type}: #{bad}", subject) if bad
        what = type == 9 ? 'SID/Label Range' : 'SRLB'
        size = ("\0".b + value.byteslice(0, 3)).unpack1('N')
        name = type == 9 ? :sid_label_range_zero : :srlb_range_zero
        found << finding(name, subject, "#{what} of size 0") if size.zero?
        labels = subs.count { _1[0] == 1 }
        found << finding(:range_two_sid_labels, subject, "#{what} with #{labels} SID/Label sub-TLVs") if labels > 1
      end
      found
    end

    # An extended prefix (RFC 7684 section 2.1) or link (3.1) LSA: TLV
    # +want+, +fixed+ octets, then sub-TLVs, each given to the block.
    def extended(body, subject, want, fixed)
      list, bad = tlvs(body)
      return overrun(bad, subject) if bad
      list.flat_map do |type, value|
        next [] unless type == want
        return overrun("TLV #{type} of length #{value.bytesize}, less than its #{fixed} fixed octets", subject) if value.bytesize < fixed
        subs, bad = tlvs(value.byteslice(fixed..))
        return overrun("in TLV #{type}: #{bad}", subject) if bad
        block_given? ? subs.flat_map { yield _1 } : []
      end
    end

    # The same TLV 1 twice in one extended LSA: the block gives what makes
    # two the same (a prefix and its length; any two links).
    def twice(body, subject, name)
      list, bad = tlvs(body)
      return [] if bad
      keys = list.select { _1[0] == 1 && _1[1].bytesize >= 8 }.map { yield _1[1] }
      dup = keys.tally.values.max.to_i
      return [] if dup < 2
      [finding(name, subject, "#{dup} #{name == :link_tlv_twice ? 'Extended Link TLVs' : 'Extended Prefix TLVs for one prefix'}")]
    end

    V_FLAG = 0x08
    L_FLAG = 0x04

    ADJ_V = 0x40
    ADJ_L = 0x20

    # RFC 8665 section 6.1 and 6.2: an Adj-SID's V and L, as a Prefix-SID's.
    def adj_sid((type, value), subject)
      return [] unless [2, 3].include?(type) && value.bytesize >= 1
      flags = value.getbyte(0)
      v = flags.anybits?(ADJ_V)
      l = flags.anybits?(ADJ_L)
      return [] if v == l
      what = type == 2 ? 'Adj-SID' : 'LAN Adj-SID'
      [finding(:adj_sid_vl_invalid, subject, "#{what} flags 0x#{flags.to_s(16).rjust(2, '0')}: #{v ? 'V' : 'L'} set, #{v ? 'L' : 'V'} clear")]
    end

    # Two Prefix-SIDs for one MT-ID and algorithm in one Extended Prefix
    # TLV (RFC 8665 section 5).
    def multiple_sids(body, subject)
      list, bad = tlvs(body)
      return [] if bad
      list.flat_map do |type, value|
        next [] unless type == 1 && value.bytesize >= 8
        subs, bad = tlvs(value.byteslice(8..))
        next [] if bad
        keys = subs.select { _1[0] == 2 && _1[1].bytesize >= 4 }.map { _1[1].byteslice(2, 2) }
        twice = keys.tally.select { |_, n| n > 1 }
        twice.map do |k, n|
          mt, algo = k.unpack('CC')
          finding(:prefix_sid_multiple, subject, "#{n} Prefix-SIDs for MT-ID #{mt}, algorithm #{algo}")
        end
      end
    end

    # RFC 8665 section 5: V and L both clear (an index) or both set (a label).
    def prefix_sid((type, value), subject)
      return [] unless type == 2 && value.bytesize >= 1
      flags = value.getbyte(0)
      v = flags.anybits?(V_FLAG)
      l = flags.anybits?(L_FLAG)
      return [] if v == l
      [finding(:prefix_sid_vl_invalid, subject, "Prefix-SID flags 0x#{flags.to_s(16).rjust(2, '0')}: #{v ? 'V' : 'L'} set, #{v ? 'L' : 'V'} clear")]
    end
  end
end
