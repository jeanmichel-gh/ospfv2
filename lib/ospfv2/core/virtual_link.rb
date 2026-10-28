# frozen_string_literal: true

require_relative 'interface'

module OSPFv2
  module Core
    # A virtual link (RFC 2328 15): a point-to-point backbone interface to
    # another area border router, carried across a non-backbone transit
    # area. It has no wire of its own: packets go as unicast to the other
    # end's address, out of whichever interface the transit area's SPF
    # reaches it by, and come back on that area's interfaces marked with
    # the backbone's area id.
    #
    # It comes up when the transit area's SPF reaches the other end and
    # goes down when it no longer does. Its cost is that path's cost.
    class VirtualLink < Interface
      attr_reader :neighbor_id, :transit_area_id, :remote, :via

      # Hands our packets to the instance, which sends them through the
      # transit area.
      class Transport
        def initialize(link) = @link = link
        def start(&) = nil
        def stop = nil
        def send_packet(bytes, dest) = @link.instance.virtual_send(@link, bytes, dest)
      end

      # opts: hello_interval, dead_interval, rxmt_interval, transmit_delay, auth
      def initialize(instance, neighbor_id:, transit_area_id:, area:, **opts)
        @neighbor_id = Addr.to_i(neighbor_id)
        @transit_area_id = Addr.to_i(transit_area_id)
        @remote = 0
        @via = nil
        super(instance, name: "vl-#{Addr.to_s(@neighbor_id)}", address: '0.0.0.0/32', area: area,
                        transport: Transport.new(self), type: :p2p, **opts)
      end

      def virtual? = true

      # Hellos on a virtual link carry a zero mask (A.3.2).
      def mask = 0

      def hello_destination = @remote
      def flood_destination = @remote

      # The transit area's SPF reaches the other end: +cost+ to it, our
      # +local+ address on the way, its +remote+ address, out of interface
      # +via+.
      def reach(cost:, local:, remote:, via:)
        cost = cost.clamp(1, 65_535)
        changed = [@cost, @address, @remote] != [cost, local, remote]
        @cost = cost
        @address = local
        @remote = remote
        @via = via
        if !up?
          @instance.log(:info, self, "virtual link to #{Addr.to_s(@neighbor_id)} up, cost #{cost}, " \
                                     "via #{Addr.to_s(remote)} #{via}",
                        kind: :virtual_link, to: 'up', neighbor_id: Addr.to_s(@neighbor_id), cost: cost)
          up
        elsif changed
          @area.schedule_origination
        end
      end

      # The other end is gone from the transit area.
      def unreach
        return unless up?
        @instance.log(:info, self, "virtual link to #{Addr.to_s(@neighbor_id)} down: not reachable in area " \
                                   "#{Addr.to_s(@transit_area_id)}",
                      kind: :virtual_link, to: 'down', neighbor_id: Addr.to_s(@neighbor_id))
        down
      end

      def summary
        super.merge(type: :virtual, neighbor_id: Addr.to_s(@neighbor_id), transit_area: Addr.to_s(@transit_area_id),
                    remote: Addr.to_s(@remote), via: @via)
      end
    end
  end
end
