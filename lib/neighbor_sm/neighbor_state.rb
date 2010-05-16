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