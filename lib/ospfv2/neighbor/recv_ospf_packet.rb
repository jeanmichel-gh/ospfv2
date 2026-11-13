#--
# Copyright 2010 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#++

require_relative 'recv_database_description'

module OSPFv2
  class Neighbor

    # Entry point for every received packet (called with the lock held).
    # Performs the RFC 2328 8.2 checks that matter for a simulator, then
    # dispatches to recv_<packet_name>. The Interface has checked the area
    # and the router id, and sends a packet here only from this neighbor
    # (docs/design/sim-dr-bdr.md).
    def receive(packet, from)
      log :rcv, packet unless packet.is_a?(Hello) # the Interface logged it
      handler = "recv_#{packet.name}"
      if respond_to?(handler)
        __send__ handler, packet, from
      else
        log :drop, "no handler for #{packet.name}"
      end
    end

    def recv_hello(hello, from, *)
      @neighbor_ip = from
      @neighbor_router_id = hello.router_id
      @state.recv_hello self, hello, from
    end

    def from_peer?(from)
      from.nil? || from == @neighbor_ip
    end

    def recv_link_state_request(ls_request, from, *)
      return unless @ls_db
      unless in_state?(:exchange, :loading, :full)
        debug "ignoring link state request received while in #{state}"
        return
      end
      send_packet ls_request.to_lsu(@ls_db, area_id: @area_id, router_id: @router_id), from
    end

    def recv_link_state_update(ls_update, from, *)
      unless in_state?(:full, :loading, :exchange)
        debug "ignoring link state update received while in #{state}"
        return
      end
      ls_ack = LinkStateAck.ack_ls_update ls_update, area_id: @area_id, router_id: @router_id
      send_packet ls_ack, flooding_address
      unless @ls_req_list.empty?
        ls_update.each do |l|
          next unless @ls_req_list.key?(l.key)
          debug "deleting #{l.key.inspect} from Ls Req List"
          @ls_req_list.delete(l.key)
        end
        new_state NeighborState::Full.new, 'loading_done' if @ls_req_list.empty? && state == :loading
      end
      return unless @ls_db
      # Our own LSA echoed back is an ack from this neighbor only.
      @ls_db.recv_link_state_update ls_update, implied_ack: lambda { |ours|
        @acked[ours.key] = instance(ours)
        @interface.ack_if_all(ours)
      }
    end

    # An ack counts for this neighbor only; the LSA's flag clears once
    # every adjacency has acked it (RFC 2328 13.7).
    def recv_link_state_ack(ls_ack, *)
      return unless @ls_db
      ls_ack.each do |hdr|
        lsa = @ls_db.lookup(hdr)
        next unless lsa && (lsa <=> hdr).zero?
        @acked[lsa.key] = instance(lsa)
        @interface.ack_if_all(hdr)
      end
    end
  end
end
