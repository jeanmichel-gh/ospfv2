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
    # dispatches to recv_<packet_name>.
    def receive(packet, from)
      if packet.area_id.to_i != @area_id.to_i
        log :drop, "#{packet.name} from #{from}: area #{packet.area_id.to_ip} != #{@area_id.to_ip}"
        return
      end
      if packet.router_id.to_i == @router_id.to_i
        log :drop, "#{packet.name} from #{from}: our own router id #{@router_id.to_ip}"
        return
      end
      log :rcv, packet
      handler = "recv_#{packet.name}"
      if respond_to?(handler)
        __send__ handler, packet, from
      else
        log :drop, "no handler for #{packet.name}"
      end
    end

    def recv_hello(hello, from, *)
      if (errs = hello_mismatch(hello)).any?
        log :drop, "hello from #{from} rejected: #{errs.join(', ')}"
        return
      end
      @neighbor_ip = from
      @neighbor_router_id = hello.router_id
      @state.recv_hello self, hello, from
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
      @ls_db.recv_link_state_update ls_update if @ls_db
    end

    def recv_link_state_ack(ls_ack, *)
      return unless @ls_db
      before = @ls_db.all_not_acked.size
      ls_ack.each { |lsa| @ls_db.ls_ack lsa }
      debug "number of lsa acked: #{before - @ls_db.all_not_acked.size}"
    end
  end
end
