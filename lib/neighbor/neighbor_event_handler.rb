#--
# Copyright 2010 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
# OSPFv2 is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# OSPFv2 is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with OSPFv2.  If not, see <http://www.gnu.org/licenses/>.
#++


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