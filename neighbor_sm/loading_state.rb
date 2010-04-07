require 'neighbor_sm/neighbor_state'
module OSPFv2
  module NeighborState
    class Loading < State
      def initialize(neighbor)
        neighbor.start_periodic_rxmt
        neighbor.start_ls_refresh
      end
    end
  end
end
