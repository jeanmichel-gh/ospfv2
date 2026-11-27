# frozen_string_literal: true

require_relative 'lsdb'
require_relative 'extended'

module OSPFv2
  module Core
    # One OSPF area: its link state database, its interfaces, and the
    # router-LSA, network-LSAs and, on an area border router, the
    # summary-LSAs this router originates into it (RFC 2328 12.4.1 to
    # 12.4.3).
    class Area
      attr_reader :id, :instance, :lsdb, :interfaces

      def initialize(instance, id)
        @instance = instance
        @id = id
        @lsdb = Lsdb.new(instance.loop.clock)
        @interfaces = []
        @pending = false
        @summaries = {} # key => spec, the summary-LSAs we want here
        @nssa_lsas = {} # key => spec, the type 7 LSAs we want here (NSSA)
        @sr_specs = {}  # key => spec, our extended prefix and link LSAs here (SR)
      end

      attr_reader :summaries, :nssa_lsas

      # Sets the type 7 LSAs this router wants in the area (RFC 3101).
      def nssa_lsas=(specs)
        old = @nssa_lsas
        @nssa_lsas = specs
        specs.each_value { |spec| @instance.originate(self, spec) }
        (old.keys - specs.keys).each { |key| @instance.flush_own(self, key) }
      end

      # Sets the summary-LSAs this router wants in the area: new and
      # changed ones are originated, the rest flushed.
      def summaries=(specs)
        old = @summaries
        @summaries = specs
        specs.each_value { |spec| @instance.originate(self, spec) }
        (old.keys - specs.keys).each { |key| @instance.flush_own(self, key) }
      end

      # An interface of ours here is up: the area counts as attached.
      def active? = @interfaces.any?(&:up?)

      # Stub settings, { default_metric:, no_summaries: }, or nil: kept on
      # the instance so they outlive the Area object.
      def stub = @instance.area_options.dig(@id, :stub)
      def stub? = !stub.nil?

      # NSSA settings (RFC 3101), { default_lsa: { metric:, type: }, no_summaries: }, or nil.
      def nssa = @instance.area_options.dig(@id, :nssa)
      def nssa? = !nssa.nil?

      # AS-external LSAs flood here: neither a stub nor an NSSA.
      def external_capable? = !stub? && !nssa?

      # Options in our hellos and DDs: E in a normal area, N in an NSSA.
      def options = nssa? ? 0x08 : (external_capable? ? 0x02 : 0x00)

      # Options in our LSAs here (in an LSA, 0x08 is the type 7 P bit).
      def lsa_options = external_capable? ? 0x02 : 0x00

      def id_s = Addr.to_s(@id)

      # Something changed that may change our LSAs. Coalesces every change
      # made in one turn of the loop into one origination pass.
      def schedule_origination
        return if @pending
        @pending = true
        @instance.loop.post do
          @pending = false
          originate
        end
      end

      # Builds the LSAs this router wants in the area and hands each one
      # to the instance, which originates it if it changed.
      def originate
        return unless @instance.areas[@id].equal?(self) # the area was dropped
        @instance.originate(self, router_lsa_spec)
        @interfaces.each do |iface|
          key = [2, iface.address, @instance.router_id]
          if (spec = network_lsa_spec(iface))
            @instance.originate(self, spec)
          else
            @instance.flush_own(self, key)
          end
        end
        if (ri = @instance.ri_spec)
          @instance.originate(self, ri)
        else
          @instance.flush_own(self, [10, Instance::RI_ID, @instance.router_id])
        end
        @instance.opaque_specs_for(self).each { |spec| @instance.originate(self, spec) }
        sr = sr_specs
        (@sr_specs.keys - sr.keys).each { |key| @instance.flush_own(self, key) }
        @sr_specs = sr
        sr.each_value { |spec| @instance.originate(self, spec) }
      end

      # Does this router still want an LSA with +key+ in this area? Used
      # when a copy of one of our own LSAs comes back (RFC 2328 13.4).
      def wants?(key)
        type, ls_id, = key
        case type
        when 1 then ls_id == @instance.router_id
        when 2 then @interfaces.any? { |i| i.address == ls_id && network_lsa_spec(i) }
        when 3, 4 then @summaries.key?(key)
        when 5 then @instance.externals.key?(key)
        when 7 then @nssa_lsas.key?(key)
        when 10, 11
          if key[0] == 10 && ls_id == Instance::RI_ID && key[2] == @instance.router_id
            !@instance.ri_spec.nil?
          elsif @sr_specs.key?(key)
            true
          else
            !@instance.opaque_spec(self, key).nil?
          end
        else false
        end
      end

      def spec_for(key)
        case key[0]
        when 1 then key[1] == @instance.router_id ? router_lsa_spec : nil
        when 2 then network_lsa_spec(@interfaces.find { |i| i.address == key[1] })
        when 3, 4 then @summaries[key]
        when 5 then @instance.externals[key]
        when 7 then @nssa_lsas[key]
        when 10, 11
          if key[0] == 10 && key[1] == Instance::RI_ID && key[2] == @instance.router_id then @instance.ri_spec
          elsif @sr_specs.key?(key) then @sr_specs[key]
          else @instance.opaque_spec(self, key)
          end
        end
      end

      # Flushes our SR LSAs here, as opaque goes off.
      def flush_sr
        @sr_specs.each_key { |key| @instance.flush_own(self, key) }
        @sr_specs = {}
      end

      # Our SR LSAs in this area (RFC 8665 section 7), by key, while SR
      # and opaque are on:
      # - the Node-SID: an extended prefix LSA, 7.0.0.1, for the router
      #   ID's /32 when a passive interface here holds it; route type 1
      #   (intra-area), N set, the index, NP and E clear (PHP);
      # - an extended link LSA per link of our router-LSA that has an
      #   adjacency: on point-to-point, an Adj-SID per full neighbor
      #   (7.4.1); on a transit link, an Adj-SID to the DR and a LAN
      #   Adj-SID for each other full neighbor (7.4.2). V and L set, a
      #   label from the SRLB, B and P clear.
      def sr_specs
        sr = @instance.segment_routing
        return {} unless sr && @instance.opaque?
        me = @instance.router_id
        specs = {}
        if sr[:index] && @interfaces.any? { |i| i.passive? && i.address == me && i.prefix_len == 32 }
          sid = ExtendedPrefix::PrefixSid.new(flags: 0, sid: sr[:index])
          body = ExtendedPrefix::Body.new(tlvs: [ExtendedPrefix::Prefix.new(route_type: 1, prefix: "#{Addr.to_s(me)}/32",
                                                                            flags: ExtendedPrefix::N_FLAG, subs: [sid])])
          ls_id = (ExtendedPrefix::OPAQUE_TYPE << 24) | 1
          specs[[10, ls_id, me]] = { type: 10, ls_id: ls_id, body: body.encode }
        end
        live_labels = []
        live_links = []
        @interfaces.each do |iface|
          next unless iface.up? && !iface.passive? && !iface.virtual? && !Array(sr[:no_adj_sid]).include?(iface.name)
          sr_links(iface).each do |key, subs|
            live_links << key
            oid = @instance.link_oid(self, key)
            subs = subs.filter_map do |kind, n|
              label = @instance.adj_label(iface, n) or next
              live_labels << [iface.name, n.router_id]
              fields = { flags: ExtendedLink::AdjSid::V | ExtendedLink::AdjSid::L, weight: 0, sid: label }
              kind == :lan ? ExtendedLink::LanAdjSid.new(**fields, neighbor: Addr.to_s(n.router_id)) : ExtendedLink::AdjSid.new(**fields)
            end
            next if subs.empty?
            type, id, data = key
            link = ExtendedLink::Link.new(link_type: type, link_id: Addr.to_s(id), link_data: Addr.to_s(data), subs: subs)
            ls_id = (ExtendedLink::OPAQUE_TYPE << 24) | oid
            specs[[10, ls_id, me]] = { type: 10, ls_id: ls_id, body: ExtendedLink::Body.new(tlvs: [link]).encode }
          end
        end
        @instance.release_adj_labels(self, live_labels)
        @instance.release_link_oids(self, live_links)
        specs
      end

      private

      # The links of +iface+ in our router-LSA that have an adjacency, with
      # the neighbors each Adj-SID is for: { [type, id, data] => [[:adj | :lan, neighbor]] }.
      def sr_links(iface)
        if iface.p2p?
          iface.full_neighbors.to_h { |n| [[1, n.router_id, iface.address], [[:adj, n]]] }
        elsif transit?(iface)
          full = iface.full_neighbors
          subs = full.map { |n| [n.address == iface.dr ? :adj : :lan, n] }
          { [2, iface.dr, iface.address] => subs.sort_by { _1[0] == :adj ? 0 : 1 } }
        else
          {}
        end
      end

      # RFC 2328 12.4.1.
      def router_lsa_spec
        links = []
        @interfaces.each do |iface|
          next unless iface.up?
          if iface.virtual?
            # A virtual link, once its adjacency is full (12.4.1.3).
            iface.full_neighbors.each do |n|
              links << { type: 4, id: n.router_id, data: iface.address, metric: iface.cost }
            end
            next
          end
          stub = { type: 3, id: iface.network, data: iface.mask, metric: iface.cost }
          if iface.passive?
            links << stub
          elsif iface.p2p?
            iface.full_neighbors.each do |n|
              links << { type: 1, id: n.router_id, data: iface.address, metric: iface.cost }
            end
            links << stub
          elsif iface.state == :waiting
            links << stub
          elsif transit?(iface)
            links << { type: 2, id: iface.dr, data: iface.address, metric: iface.cost }
          else
            links << stub
          end
        end
        # B and E bits (A.4.2). No E bit in a stub area: no externals
        # there. In an NSSA, E when we bring routes in as type 7 (RFC 3101).
        asbr = nssa? ? @instance.exporting? : (@instance.asbr? && external_capable?)
        flags = (@instance.abr? ? 1 : 0) | (asbr ? 2 : 0)
        flags |= 4 if transit_for_virtual_link? # V bit
        { type: 1, ls_id: @instance.router_id, body: router_body(links, flags) }
      end

      # A full virtual link crosses this area: the V bit in our router-LSA.
      def transit_for_virtual_link?
        @instance.virtual_links.each_value.any? { |v| v.transit_area_id == @id && v.full_neighbors.any? }
      end

      # A broadcast segment is transit when we are fully adjacent with the
      # DR, or we are the DR with at least one full neighbor.
      def transit?(iface)
        return iface.full_neighbors.any? if iface.dr?
        iface.full_neighbors.any? { |n| n.address == iface.dr }
      end

      def router_body(links, flags)
        body = [flags, 0, links.size].pack('CCn')
        links.each { |l| body << [l[:id], l[:data], l[:type], 0, l[:metric]].pack('NNCCn') }
        body
      end

      # RFC 2328 12.4.2: the DR of a segment with at least one full
      # neighbor describes it.
      def network_lsa_spec(iface)
        return unless iface&.broadcast? && iface.dr? && !iface.passive?
        full = iface.full_neighbors
        return if full.empty?
        routers = [@instance.router_id, *full.map(&:router_id)]
        { type: 2, ls_id: iface.address, body: [iface.mask, *routers].pack('N*') }
      end
    end
  end
end
