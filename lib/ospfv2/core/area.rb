# frozen_string_literal: true

require_relative 'lsdb'

module OSPFv2
  module Core
    # One OSPF area: its link state database, its interfaces, and the
    # router-LSA and network-LSAs this router originates into it
    # (RFC 2328 12.4.1, 12.4.2).
    class Area
      attr_reader :id, :instance, :lsdb, :interfaces

      def initialize(instance, id)
        @instance = instance
        @id = id
        @lsdb = Lsdb.new(instance.loop.clock)
        @interfaces = []
        @pending = false
      end

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
        when 1 then true
        when 2 then @interfaces.any? { |i| i.address == ls_id && network_lsa_spec(i) }
        else false
        end
      end

      def spec_for(key)
        case key[0]
        when 1 then router_lsa_spec
        when 2 then network_lsa_spec(@interfaces.find { |i| i.address == key[1] })
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
        { type: 1, ls_id: @instance.router_id, body: router_body(links) }
      end

      # A broadcast segment is transit when we are fully adjacent with the
      # DR, or we are the DR with at least one full neighbor.
      def transit?(iface)
        return iface.full_neighbors.any? if iface.dr?
        iface.full_neighbors.any? { |n| n.address == iface.dr }
      end

      def router_body(links)
        body = [0, 0, links.size].pack('CCn')
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
