
require 'neighbor_sm/neighbor_state'
module OSPFv2
  module NeighborState
    class Full < State
      def recv_link_state_ack(neighbor, link_state_ack)
        neighbor.debug "*** in full state object ev recv_link_state_ack ????? ****"
      end
      def recv_dd(neighbor, dd)
        new_state neighbor, ExStart.new(neighbor), 'Received DatabaseDescription'
      end
    end
  end
end
