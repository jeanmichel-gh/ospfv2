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

    # RFC 2328 8.2 sanity checks on raw OSPF bytes. Returns nil when the
    # packet is acceptable, else the reason to drop it. The checksum is
    # only defined for null and simple password authentication.
    def self.invalid?(bytes)
      return 'shorter than an OSPF header' if bytes.bytesize < 24
      version, _type, len = bytes.unpack('CCn')
      return "version #{version}" unless version == 2
      return "length field #{len} > #{bytes.bytesize} bytes received" if len > bytes.bytesize || len < 24
      au_type = bytes.byteslice(14, 2).unpack1('n')
      return nil if au_type == 2 # cryptographic: no checksum
      data = bytes.byteslice(0, 16) + bytes.byteslice(24, len - 24)
      data += "\0" if data.bytesize.odd?
      sum = data.unpack('n*').sum
      sum = (sum & 0xffff) + (sum >> 16) while sum > 0xffff
      sum == 0xffff ? nil : 'bad checksum'
    end

    private

    def dispatch(ev_type, ev)
      case ev_type
      when :ev_recv
        bytes, from = ev
        unless (why = self.class.invalid?(bytes)).nil?
          @neighbor.log :drop, "packet from #{from}: #{why}"
          return
        end
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
