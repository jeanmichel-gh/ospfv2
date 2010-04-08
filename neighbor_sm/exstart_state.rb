require 'neighbor_sm/neighbor_state'
module OSPFv2
  module NeighborState
    
    class ExStart < State
      def initialize(n)
        @neighbor = n
         n.instance_eval do
          @last_dd_seqn = dd_sequence_number
          
          #-- could be a State#reset method inherited ?
          @ls_db.reset if @ls_db
          @ls_req_list={}
          @periodic_refresh.cancel
          @periodic_rxmt.cancel
          #--
          
          dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id, 
                                        :imms=>7, :dd_sequence_number => (@last_dd_seqn = dd_sequence_number)
          send_dd dd, true
        end
        
      end
      
      def negotiation_done
        @neighbor.instance_eval do
          dd_rxmt_interval.cancel
          new_state Exchange.new
        end
      end

      def adj_ok?
         if ! ok
          change_state(@neighbor, Two_way.new)
        end

      end

    end
  end
end
