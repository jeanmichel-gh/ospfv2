
module OSPFv2
  
  class NeighborEventHandler

    def initialize(neighbor)
      @neighbor = neighbor
      @evQ = Queue.new
      start_event_loop
    end

    def update(*args)
      @evQ.enq(args)
    end
    
    def start_event_loop
      @neighbor.debug "*** Event Loop Started ***"
      Thread.new(@evQ) do |events|
        loop do
          ev_type, *ev = events.deq
          case ev_type
          when :ev_recv
            bits, from, @port = ev
            packet = OspfPacket.factory(bits[20..-1])
            if packet
              @neighbor.log :rcv, packet
              @neighbor.__send__ "recv_#{packet.name}", packet, from, @port
            else
              STDERR.puts "Not an ospf packet: #{bits.unpack('H*')}"
            end
          else
            @neighbor.log ev_type, ev.inspect
          end
        end
      end
    end

  end
end