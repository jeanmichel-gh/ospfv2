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

require 'neighbor_sm/neighbor_state'
module OSPFv2
  module NeighborState

    class ExStart < State
      def initialize(n)
        @neighbor = n
        n.instance_eval do
          @last_dd_seqn = n.dd_sequence_number

          #-- could be a State#reset method inherited ?
          @ls_db.reset if @ls_db
          @ls_req_list={}
          @periodic_refresh.cancel
          @periodic_rxmt.cancel
          #--

          @last_dd_seqn = dd_sequence_number
          raise unless @last_dd_seqn>0

          dd = DatabaseDescription.new :router_id=> @router_id, :area_id=> @area_id, 
          :imms=>7, :dd_sequence_number => @last_dd_seqn
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
