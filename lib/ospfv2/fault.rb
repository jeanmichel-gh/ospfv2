# frozen_string_literal: true

require_relative 'core/addr'
require_relative 'core/lsa'
require_relative 'core/validation'

module OSPFv2
  # Opaque and SR LSAs that are wrong on purpose, each named after the
  # finding it makes (docs/design/sr-ospf.md, step 0). The tests send
  # them to ospfd, and the simulator's POST /api/fault floods one.
  #
  # An entry is [name, finding, description, build]. +build+ takes a
  # context and gives [LS type, link state ID, body]. What the RFC
  # expects and its text come from the finding's rule in
  # OSPFv2::Validation, so the two cannot drift apart. Building never
  # validates.
  #
  # RFC 2328's own entries (header, Hello, DD, LSU) are routescope
  # protocol-conventions' item, not these.
  module Fault
    # The opaque types (RFC 5250 section 3): Router Information (RFC
    # 7770), extended prefix and extended link (RFC 7684).
    RI = Validation::OPAQUE_RI
    EXT_PREFIX = Validation::OPAQUE_EXT_PREFIX
    EXT_LINK = Validation::OPAQUE_EXT_LINK

    CATALOG = [
      [:opaque_as_in_stub, :opaque_as_in_stub, 'a correct Router Information LSA, flooded as a type 11 into a stub area',
       ->(c) { [11, opaque_id(RI, 0), Fault.router_information(c)] }],
      [:sr_algorithm_twice, :sr_algorithm_twice, 'a Router Information LSA with two SR-Algorithm TLVs',
       ->(c) { [10, opaque_id(RI, 0), Fault.router_information(c, algorithms: [[0], [0, 1]])] }],
      [:sid_label_range_zero, :sid_label_range_zero, 'a Router Information LSA whose SID/Label Range has size 0',
       ->(c) { [10, opaque_id(RI, 0), Fault.router_information(c, srgb: [c[:srgb][0], 0])] }],
      [:srlb_range_zero, :srlb_range_zero, 'a Router Information LSA whose SR Local Block has size 0',
       ->(c) { [10, opaque_id(RI, 0), Fault.router_information(c, srlb: [c[:srlb][0], 0])] }],
      [:range_two_sid_labels, :range_two_sid_labels, 'a Router Information LSA whose SID/Label Range has two SID/Label sub-TLVs',
       ->(c) { [10, opaque_id(RI, 0), Fault.router_information(c, srgb_subs: 2)] }],
      [:prefix_sid_vl_invalid, :prefix_sid_vl_invalid, 'an extended prefix LSA whose Prefix-SID has V set and L clear',
       ->(c) { [10, opaque_id(EXT_PREFIX, 1), Fault.extended_prefix(c, flags: V_FLAG)] }],
      [:prefix_tlv_twice, :prefix_tlv_twice, 'an extended prefix LSA with the Extended Prefix TLV for its /32 twice',
       ->(c) { [10, opaque_id(EXT_PREFIX, 1), Fault.extended_prefix(c) * 2] }],
      [:link_tlv_twice, :link_tlv_twice, 'an extended link LSA with two Extended Link TLVs',
       ->(c) { [10, opaque_id(EXT_LINK, 1), Fault.extended_link(c) + Fault.extended_link(c, link_id: '10.255.0.8')] }],
      [:adj_sid_vl_invalid, :adj_sid_vl_invalid, 'an extended link LSA whose Adj-SID has V set and L clear',
       ->(c) { [10, opaque_id(EXT_LINK, 1), Fault.extended_link(c, flags: 0x40)] }],
      [:tlv_overrun, :tlv_overrun, 'an extended prefix LSA whose Prefix-SID sub-TLV runs 4 octets past its TLV',
       ->(c) { [10, opaque_id(EXT_PREFIX, 1), Fault.extended_prefix(c, overrun: 4)] }]
    ].freeze

    V_FLAG = Validation::V_FLAG
    L_FLAG = Validation::L_FLAG
    N_FLAG = 0x40 # RFC 7684 section 2.1

    module_function

    def opaque_id(type, id) = Core::Addr.to_s((type << 24) | id)

    def catalog
      CATALOG.map do |name, finding, description, build|
        rule = Validation.rule(finding)
        { name: name, finding: finding, description: description, group: rule.group,
          expect: rule.actions.fetch(:rfc), rfc: rule.clause, build: build }
      end
    end

    def names = CATALOG.map(&:first)

    def entry(name)
      catalog.find { _1[:name] == name.to_sym } or
        raise ArgumentError, "unknown fault #{name.inspect}; the faults are #{names.join(', ')}"
    end

    # A correct router's values, the ones an entry does not change.
    def context(router_id: '10.255.0.9', index: 9, srgb: [16_000, 8_000], srlb: [15_000, 1_000], seq: 0x8000_0001)
      { router_id: router_id, index: index, srgb: srgb, srlb: srlb, seq: seq }
    end

    # The entry as a Core::Lsa.
    def lsa(name, **ctx)
      c = context(**ctx)
      type, ls_id, body = entry(name)[:build].call(c)
      Core::Lsa.build(type: type, ls_id: ls_id, advr: c[:router_id], seq: c[:seq], body: body, options: 0x42)
    end

    # The octets it travels in.
    def wire(name, **) = lsa(name, **).bytes

    # ---- TLVs (RFC 7770 section 2.3, RFC 7684 section 2): padded to 4 octets

    def tlv(type, value)
      value = value.b
      [type, value.bytesize].pack('nn') + value + ("\0" * (-value.bytesize % 4))
    end

    def three(n) = [n].pack('N').byteslice(1, 3)

    # RFC 8665 section 2.1: a 3-octet label.
    def sid_label(label) = tlv(1, three(label))

    # RFC 8665 sections 3.2 (type 9) and 3.3 (type 14).
    def range(type, (first, size), subs: 1) = tlv(type, three(size) + "\0" + (sid_label(first) * subs))

    # A Router Information body: capabilities (RFC 7770 section 2.4),
    # then each SR-Algorithm TLV (8665 section 3.1), the SRGB and the
    # SRLB. A correct one with no options.
    def router_information(c, algorithms: [[0]], srgb: c[:srgb], srlb: c[:srlb], srgb_subs: 1)
      tlv(1, [0].pack('N')) + algorithms.map { tlv(8, _1.pack('C*')) }.join + range(9, srgb, subs: srgb_subs) +
        range(14, srlb)
    end

    # An extended prefix body (RFC 7684 section 2.1): the router ID's /32,
    # intra-area, N set, with a Prefix-SID (RFC 8665 section 5) of
    # +flags+. +overrun+ octets more in the sub-TLV's length than it has.
    def extended_prefix(c, flags: 0, overrun: 0)
      sid = flags.anybits?(V_FLAG) && flags.anybits?(L_FLAG) ? three(c[:index]) : [c[:index]].pack('N')
      value = [flags, 0, 0, 0].pack('C4') + sid
      sub = [2, value.bytesize + overrun].pack('nn') + value
      tlv(1, [1, 32, 0, N_FLAG].pack('C4') + [Core::Addr.to_i(c[:router_id])].pack('N') + sub)
    end

    # An extended link body (RFC 7684 section 3.1): a point-to-point link
    # to +link_id+, with an Adj-SID (RFC 8665 section 6.1), V and L set,
    # a label from the SRLB.
    def extended_link(c, link_id: '10.255.0.7', data: '10.0.0.1', flags: 0x60)
      adj = tlv(2, [flags, 0, 0, 0].pack('C4') + three(c[:srlb][0]))
      tlv(1, [1, 0, 0, 0].pack('C4') + [Core::Addr.to_i(link_id), Core::Addr.to_i(data)].pack('NN') + adj)
    end
  end
end
