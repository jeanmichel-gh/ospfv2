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
    
    class Init < State

      # recv_hello inherited
      
      def recv_hello(neighbor, hello, *args)
         super
         two_way_received(neighbor) if hello.has_neighbor?(neighbor.router_id)
       end

      def two_way_received(neighbor, *args)
        change_state(neighbor, ExStart.new(neighbor), 'two_way_received' )
      end
    end
    
  end
end

