
module OSPFv2
  module NeighborState
    class State

      def change_state(neighbor, *args)
        neighbor.change_state(*args)
      end
      alias :new_state :change_state

      def kill_nbr(neighbor)
        new_state neighbor, Down.new, 'll_down or kill_nbr'
      end
      alias :ll_down :kill_nbr
      
      def inactivity_timer(neighbor)
        
        neighbor.instance_eval {
          @ls_db.reset if @ls_db
          @ls_req_list={}
          @periodic_refresh.cancel
          @periodic_rxmt.cancel
        }
        
        new_state neighbor, Down.new, 'Inactivity Timer'
      end
      
      def recv_hello(neighbor, rcv_hello, *args)
        neighbor.instance_eval {
          hello.add_router_id rcv_hello
          hello.designated_router_id = rcv_hello.designated_router_id.to_ip
          inactivity_timer.start { new_state Down.new, 'Inactivity Timer' }
        }
      end

      def adj_ok?
      end
      def seq_number_mismatch(neighbor)
      end
      def bad_ls_req(neighbor)
      end
      def one_way_received(neighbor)
      end
      def two_way_received(neighbor)
      end
      
      def method_missing(method, *args, &block)
        if method.to_s =~ /^recv_(.+)$/
          args[0].__send__ debug,  "*** ignoring packet #{$1} : received  while in #{self} ***"
        else
          raise
        end
      end

    end
  end
end

require 'neighbor_sm/down_state'
require 'neighbor_sm/attempt_state'
require 'neighbor_sm/init_state'
require 'neighbor_sm/exstart_state'
require 'neighbor_sm/exchange_state'
require 'neighbor_sm/loading_state'
require 'neighbor_sm/full_state'