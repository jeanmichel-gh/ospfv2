# frozen_string_literal: true

require_relative 'addr'

module OSPFv2
  module Core
    # BFD for OSPF neighbors (RFC 5882): which sessions this router wants
    # from bfdd4r, and what it does when one fails.
    #
    #   bfd = Bfd.new(instance, client)   # attaches itself to the instance
    #   bfd.handle(events)                # on the loop: what the client polled
    #
    # +client+ answers want(interface:, peer:, local:, **timers) and
    # drop(interface:, peer:), as bfd4r's BFD::Client does. The events
    # handed to #handle are BFD::Client::Event: type, interface, peer,
    # state, from, diag, message, and failure?.
    #
    # The rules:
    #
    # * A neighbor on an interface with bfd-liveness-detection wants a
    #   session to its interface address once it reaches 2-Way, and lets it
    #   go when it goes Down.
    # * A neighbor never waits for BFD. OSPFv2 has no way to say it runs
    #   BFD, so the router cannot know both ends are willing (RFC 5882 4.1).
    # * A session that was Up and went Down for a reason other than
    #   AdminDown takes the neighbor Down: KillNbr, event "BFD down" (RFC
    #   5882 10.1.2). Up to AdminDown, local or remote, does nothing (RFC
    #   5882 4.2). BFD::Client#failure? is that decision.
    # * bfdd4r gone is a router that does not run BFD: every neighbor stays,
    #   and a warning says so once until bfdd4r answers again.
    #
    # Runs on the event loop thread only.
    class Bfd
      EVENT = 'BFD down'

      attr_reader :client

      def initialize(instance, client)
        @instance = instance
        @client = client
        @states = {}    # [ifname, peer] => last state told, for wanted sessions
        @wanted = {}    # [ifname, peer] => the parameters asked for
        @away = false   # warned that bfdd4r is not there
        instance.bfd = self
        instance.on_neighbor_change { |nbr, old, new| neighbor_changed(nbr, old, new) }
      end

      # What the neighbors table says: nil when the neighbor's interface
      # runs no BFD, else "up" or "down".
      def state_of(nbr)
        key = key_of(nbr)
        return nil unless @wanted.key?(key)
        @states[key] == :up ? 'up' : 'down'
      end

      # The interface's BFD settings changed (bfd= on it): sessions for its
      # neighbors are asked for again, or let go.
      def interface_changed(iface)
        iface.neighbors.each_value { |n| sync(n) }
      end

      # Events from the client, in order.
      def handle(events)
        events.each { |e| handle_one(e) }
      end

      private

      def neighbor_changed(nbr, _old, _new)
        sync(nbr)
      end

      # Wanted from 2-Way up, on an interface with BFD; not when Down.
      # Init after 2-Way (1-WayReceived) keeps the session: the neighbor is
      # still there.
      def sync(nbr)
        key = key_of(nbr)
        iface = nbr.iface
        if iface.bfd && nbr.state != :down && (nbr.at_least?(:two_way) || @wanted.key?(key))
          params = { interface: iface.name, peer: key[1], local: Addr.to_s(iface.address), **timers(iface.bfd) }
          return if @wanted[key] == params
          @wanted[key] = params
          @client.want(**params)
          @instance.log(:info, iface, "BFD session to #{key[1]} wanted",
                        kind: :bfd, peer: key[1], from: nil, to: 'wanted', diag: nil)
        elsif @wanted.delete(key)
          @states.delete(key)
          @client.drop(interface: key[0], peer: key[1])
          @instance.log(:info, iface, "BFD session to #{key[1]} let go",
                        kind: :bfd, peer: key[1], from: nil, to: 'released', diag: nil)
        end
      end

      # Junos minimum-interval is milliseconds and sets both directions;
      # bfdd4r takes microseconds, as on the wire (RFC 5880 4.1).
      def timers(opts)
        out = {}
        if (ms = opts[:minimum_interval])
          out[:desired_min_tx] = ms * 1000
          out[:required_min_rx] = ms * 1000
        end
        out[:detect_mult] = opts[:multiplier] if opts[:multiplier]
        out
      end

      def handle_one(e)
        case e.type
        when :state then session_state(e)
        when :connected
          @away = false
          @instance.log(:info, nil, "BFD: #{e.message}", kind: :bfd, bfdd4r: 'connected')
        when :lost
          @states.clear
          return if @away
          @away = true
          @instance.log(:warn, nil, "BFD: #{e.message}; neighbors stay up without BFD until bfdd4r answers",
                        kind: :bfd, bfdd4r: 'lost')
        when :error
          @instance.log(:warn, iface_named(e.interface), "BFD: #{e.message}", kind: :bfd, peer: e.peer, error: e.message)
        end
      end

      def session_state(e)
        key = [e.interface, e.peer]
        return unless @wanted.key?(key)
        @states[key] = e.state
        iface = iface_named(e.interface)
        @instance.log(:info, iface, "BFD session to #{e.peer}: #{e.from || 'unknown'} -> #{e.state}" \
                                    "#{e.diag ? " (#{e.diag})" : ''}",
                      kind: :bfd, peer: e.peer, from: e.from&.to_s, to: e.state.to_s, diag: e.diag&.to_s)
        # RFC 5882 4.2: only an Up to Down that is not AdminDown acts.
        return unless e.failure?
        nbr = iface&.neighbors&.each_value&.find { |n| Addr.to_s(n.address) == e.peer }
        # RFC 5882 10.1.2: OSPFv2 tears the neighbor down.
        nbr&.kill(EVENT)
      end

      def iface_named(name) = @instance.interfaces[name]

      def key_of(nbr) = [nbr.iface.name, Addr.to_s(nbr.address)]
    end
  end
end
