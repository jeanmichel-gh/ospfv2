#--
# Copyright 2010 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#++

module OSPFv2

  # Serializes everything that happens to a Neighbor: received packets and
  # timer events go through one queue and one thread.
  class NeighborEventHandler

    def initialize(neighbor)
      @neighbor = neighbor
      @evQ = Queue.new
      start_event_loop
    end

    # Observer callback for timers, and entry point for the transport.
    def update(*args)
      @evQ.enq(args)
    end

    def start_event_loop
      @thread = Thread.new do
        Thread.current.name = 'ospfv2-events'
        loop do
          ev_type, *ev = @evQ.deq
          begin
            dispatch(ev_type, ev)
          rescue StandardError => e
            @neighbor.log :error, "#{e.class}: #{e.message}\n  #{e.backtrace.first(6).join("\n  ")}"
          end
        end
      end
    end

    private

    def dispatch(ev_type, ev)
      case ev_type
      when :ev_recv
        bytes, from = ev
        packet = OspfPacket.factory(bytes)
        unless packet
          @neighbor.log :drop, "not an OSPF packet from #{from}: #{bytes.unpack1('H*')[0, 64]}"
          return
        end
        @neighbor.synchronize { @neighbor.receive(packet, from) }
      else
        @neighbor.debug "#{ev_type} #{ev.inspect}"
      end
    end
  end
end
