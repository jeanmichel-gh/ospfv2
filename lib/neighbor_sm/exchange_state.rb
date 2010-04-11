require 'neighbor_sm/neighbor_state'
module OSPFv2
  module NeighborState
    class Exchange < State
      def seq_number_mismatch(neighbor)
        change_state(neighor, Exstart.new, 'seq_number_mismatch')
      end
    end
  end
end