require 'neighbor_sm/neighbor_state'
module OSPFv2

  module NeighborState

    class Attempt < State

      def recv_hello(neighbor, hello, *args)
        super
        two_way_received(neighbor) if hello.has_neighbor?(neighbor.router_id)
      end
      
      def two_way_received(neighbor)
        new_state neighbor, ExStart.new(neighbor), 'two_way_received'
      end
      
    end
    
  end
  
end