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
  module LSDB
    ROUTER_ID_BASE=0x01000000
    EXTERNAL_BASE_ADDRESS='50.0.0.0/24'
    SUMMARY_BASE_ADDRESS='30.0.0.0/24'
    NETWORK_BASE_ADDRESS='20.0.0.0/24'
    LINK_BASE_ADDRESS='13.0.0.0/30'
  end
end
