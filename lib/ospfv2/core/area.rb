# frozen_string_literal: true

require_relative 'lsdb'

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
        end
      end

      private

      # RFC 2328 12.4.1.
      def router_lsa_spec
        links = []
        @interfaces.each do |iface|
          next unless iface.up?
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
        { type: 1, ls_id: @instance.router_id, body: router_body(links, flags) }
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
