# frozen_string_literal: true

require_relative 'addr'
require_relative 'validation'
require_relative 'extended'

module OSPFv2
  module Core
    # The MPLS label table SR-MPLS in OSPF gives (RFC 8665 with RFC 8660's
    # MPLS data plane; docs/design/sr-ospf.md, step 4, "Calculation"),
    # built after each SPF run from the route table, the RI and extended
    # prefix LSAs, and our own blocks. It changes neither. isisd's
    # Spf::Labels is the model.
    #
    # For a route with Prefix-SID index I:
    # - the in-label is I in our SRGB (RFC 8660 section 2.4);
    # - toward each next hop N, when N advertised the SID too: NP clear,
    #   pop (implicit null); NP and E set, explicit null; whether or not N
    #   is on the best path (RFC 8665 section 5);
    # - otherwise I in N's SRGB; N without one, or I past its end, gives
    #   that next hop no label, and the IP route stays (RFC 8660 2.10.1).
    # A prefix of ours gets a label only with NP set. Each Adj-SID of ours
    # pops toward its neighbor (RFC 8660 section 2.11).
    #
    # Only routers SPF reaches count (RFC 5250 section 3.1). A finding is
    # an OSPFv2::Validation finding, acted on under the receive policy;
    # what cannot be computed but breaks no clause is a problem.
    class SrLabels
      IMPLICIT_NULL = 3
      EXPLICIT_NULL = 0
      NP = ExtendedPrefix::PrefixSid::NP
      E = ExtendedPrefix::PrefixSid::E

      # One in-label: +op+ :swap, :php (every next hop pops) or :pop;
      # +kind+ :prefix_sid or :adj_sid; +fec+ the prefix, or the neighbor's
      # router ID; +next_hops+ [{ interface:, address:, out_label: }].
      Entry = Struct.new(:label, :op, :kind, :fec, :next_hops, keyword_init: true)

      # A router's SR state in an area: +srgb+ and +srlb+ [[first, size]],
      # +algorithms+, its Node-SID +index+ on +prefix+, or nil.
      Node = Struct.new(:area, :router_id, :srgb, :srlb, :algorithms, :index, :prefix, :self, keyword_init: true)

      attr_reader :entries, :out_labels, :sids, :nodes, :findings, :problems

      # RFC 8660 section 2.4: index I across the ranges [[first, size]],
      # "label = I - temp + Ll(j)"; nil past the end.
      def self.label_at(ranges, index)
        return nil if index.nil? || index.negative?
        temp = 0
        ranges.each do |first, size|
          return index - temp + first if index - temp < size
          temp += size
        end
        nil
      end

      # +instance+ gives the routes, the LSAs' readings and our blocks.
      def initialize(instance)
        @i = instance
        @me = instance.router_id
        @policy = instance.receive_policy
        @entries = {}
        @out_labels = {} # "p/len" => { [interface, gateway] => label }
        @sids = {}       # "p/len" => { index:, flags:, advr: }
        @nodes = {}      # [area id, router id string] => Node
        @findings = []
        @problems = []
        @xp = {}
        @ri = {}
      end

      def build
        sr = @i.segment_routing or return self
        @i.areas.each_value { |a| read_area(a) }
        own = [sr[:srgb]]
        by_index = Hash.new { |h, k| h[k] = [] }
        @i.route_table.routes.each_value do |r|
          s = route_sid(r) or next
          @sids[r.dest_s] = s
          by_index[s[:index]] << r
        end
        by_index.each do |index, routes|
          if routes.size > 1
            names = routes.map(&:dest_s).sort
            found(Validation.finding(:prefix_sid_duplicate, "index #{index}", "the Prefix-SID of #{names.join(' and ')}; both left out"))
            next
          end
          r = routes.first
          label = SrLabels.label_at(own, index)
          next problem("#{r.dest_s}: index #{index} is past our SRGB") unless label
          prefix_entry(r, @sids[r.dest_s], label)
        end
        adj_entries
        self
      end

      # The out-label for +route+'s next hop +hop+ (Spf::NextHop), or nil.
      def out_label(dest, hop) = @out_labels.dig(dest, [hop.interface, hop.gateway])

      private

      def read_area(area)
        aid = area.id
        @ri[aid] = @i.router_information(area)
        @xp[aid] = @i.extended_prefixes(area)
        (@ri[aid].values.flat_map { _1[:findings] } + @xp[aid].values.flat_map { _1[:findings] }).each do |f|
          found_hash(f.merge(area: Addr.to_s(aid)))
        end
        @ri[aid].each do |rid, r|
          next unless r[:algorithms]
          me = Addr.to_i(rid) == @me
          next unless me || @i.route_table.reached?(aid, Addr.to_i(rid))
          index, prefix = node_sid(aid, rid)
          @nodes[[aid, rid]] = Node.new(area: Addr.to_s(aid), router_id: rid, srgb: r[:srgb], srlb: r[:srlb],
                                        algorithms: r[:algorithms], index: index, prefix: prefix, self: me)
        end
      end

      # A router's Node-SID: an algorithm 0 index on a prefix with N set.
      def node_sid(aid, rid)
        (@xp.dig(aid, rid, :prefixes) || {}).each do |prefix, p|
          next unless p[:flags].anybits?(ExtendedPrefix::N_FLAG)
          s = p[:sids].find { _1[:algorithm].zero? && !_1[:flags].anybits?(ExtendedPrefix::PrefixSid::V) }
          return [s[:sid], prefix] if s
        end
        nil
      end

      # The Prefix-SID +r+'s advertiser gave it: { index:, flags:, advr: },
      # or nil. An external route's is in the AS's type 11s, read in each
      # area; the first area's is taken.
      def route_sid(r)
        aid = r.area || @i.areas.keys.first
        return nil if aid.nil? || r.advr.nil?
        advr = Addr.to_s(r.advr)
        s = sid_of(aid, advr, r.dest_s) or return nil
        node = @nodes[[aid, advr]]
        unless node&.algorithms&.include?(s[:algorithm])
          found(Validation.finding(:prefix_sid_algorithm, advr, "#{r.dest_s}: algorithm #{s[:algorithm]}, not in its SR-Algorithm TLV"),
                area: aid)
          return nil
        end
        { index: s[:sid], flags: s[:flags], advr: advr }
      end

      # An algorithm 0 index +advr+ gives +dest+ in area +aid+, or nil.
      def sid_of(aid, advr, dest)
        p = @xp.dig(aid, advr, :prefixes, dest) or return nil
        p[:sids].find { _1[:algorithm].zero? && !_1[:flags].anybits?(ExtendedPrefix::PrefixSid::V) }
      end

      def prefix_entry(r, sid, label)
        if Addr.to_i(sid[:advr]) == @me
          @entries[label] = Entry.new(label: label, op: :pop, kind: :prefix_sid, fec: r.dest_s, next_hops: []) if sid[:flags].anybits?(NP)
          return
        end
        hops = r.next_hops.filter_map do |h|
          out = out_for(r, h, sid)
          next unless out
          (@out_labels[r.dest_s] ||= {})[[h.interface, h.gateway]] = out
          { interface: h.interface, address: h.gateway && Addr.to_s(h.gateway), out_label: out }
        end
        return if hops.empty?
        op = hops.all? { _1[:out_label] == IMPLICIT_NULL } ? :php : :swap
        @entries[label] = Entry.new(label: label, op: op, kind: :prefix_sid, fec: r.dest_s, next_hops: hops)
      end

      def out_for(r, hop, sid)
        return nil unless hop.gateway
        iface = @i.interfaces[hop.interface] or return nil
        nbr = iface.neighbors.each_value.find { _1.address == hop.gateway }
        return problem("#{r.dest_s}: no neighbor at #{Addr.to_s(hop.gateway)}; that next hop gets no label") unless nbr
        rid = Addr.to_s(nbr.router_id)
        aid = iface.area.id
        if (theirs = sid_of(aid, rid, r.dest_s))
          return IMPLICIT_NULL unless theirs[:flags].anybits?(NP)
          return EXPLICIT_NULL if theirs[:flags].anybits?(E)
        end
        node = @nodes[[aid, rid]]
        label = node && !node.srgb.empty? && SrLabels.label_at(node.srgb, sid[:index])
        return label if label
        problem("#{r.dest_s}: neighbor #{rid} #{node && !node.srgb.empty? ? "has no label for index #{sid[:index]}" : 'has no SRGB'}; " \
                'that next hop gets none')
      end

      def adj_entries
        @i.adj_labels.each do |(ifname, rid), label|
          iface = @i.interfaces[ifname] or next
          nbr = iface.neighbors.each_value.find { _1.router_id == rid } or next
          @entries[label] = Entry.new(label: label, op: :pop, kind: :adj_sid, fec: Addr.to_s(rid),
                                      next_hops: [{ interface: ifname, address: Addr.to_s(nbr.address), out_label: IMPLICIT_NULL }])
        end
      end

      def problem(text)
        @problems << text unless @problems.include?(text)
        nil
      end

      # A finding from the calculation, with its area.
      def found(f, area: nil)
        found_hash(f.to_hash.merge(area: area && Addr.to_s(area)).compact)
      end

      def found_hash(h)
        @findings << h unless @findings.include?(h)
      end
    end
  end
end
