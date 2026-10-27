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
  module NeighborState

    # Base class of the RFC 2328 section 10.1 neighbor states.
    # Events a state does not handle are ignored.
    class State
      def change_state(neighbor, *args)
        neighbor.change_state(*args)
      end
      alias new_state change_state

      def start(neighbor); end

      def kill_nbr(neighbor)
        neighbor.cancel_adjacency_timers
        new_state neighbor, Down.new, 'll_down or kill_nbr' unless neighbor.state == :down
      end
      alias ll_down kill_nbr

      # Dead interval expired without a hello from the neighbor.
      def inactivity_timer(neighbor)
        neighbor.instance_eval do
          @ls_db&.reset
          @ls_req_list = {}
          hello.remove_neighbor(@neighbor_router_id.to_i) if @neighbor_router_id
          cancel_adjacency_timers
        end
        new_state neighbor, Down.new, 'Inactivity Timer'
      end

      def recv_hello(neighbor, rcv_hello, *)
        neighbor.instance_eval do
          hello.add_router_id rcv_hello
          hello.designated_router_id = rcv_hello.designated_router_id.to_ip
          inactivity_timer.start { synchronize { @state.inactivity_timer(self) } }
        end
      end

      def negotiation_done; end
      def exchange_done(neighbor); end
      def adj_ok?(neighbor); end
      def seq_number_mismatch(neighbor); end
      def bad_ls_req(neighbor); end
      def one_way_received(neighbor); end
      def two_way_received(neighbor); end

      def to_s
        self.class.to_s.split('::').last
      end

      def method_missing(method, *args, &block)
        if method.to_s.start_with?('recv_') && args[0].respond_to?(:debug)
          args[0].debug "ignoring #{method.to_s.delete_prefix('recv_')} received while in #{self}"
        else
          super
        end
      end

      def respond_to_missing?(method, include_private = false)
        method.to_s.start_with?('recv_') || super
      end
    end
  end
end
