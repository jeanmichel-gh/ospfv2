require 'neighbor_sm/neighbor_state'
module OSPFv2

  module NeighborState

    class Down < State
      
      def start(neighbor)
        neighbor.instance_eval {
          new_state Attempt.new, 'start'
        }
      end

      def recv_hello(neighbor, rcv_hello, *args)
        super
        new_state neighbor, Init.new, 'recv_hello'
      end

    end

  end

end

