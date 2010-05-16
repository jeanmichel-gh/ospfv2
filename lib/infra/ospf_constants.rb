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

  module Constant
     V2=2
     V3=3
     HELLO = 1
     DATABASE_DESCRIPTION = 2
     LINK_STATE_REQUEST = 3
     LINK_STATE_UPDATE = 4
     LINK_STATE_ACKNOWLEDGEMENT = 5
   end

  VERSION=2
  LSRefreshTime = 30*60 
  MinLSInterval = 5
  MinLSArrival = 1
  MaxAge = 3600
  CheckAge = 5*60
  MaxAgeDiff = 15*60
  LSInfinity = 0xffffffff
  DefaultDestination = "0.0.0.0"
  N = 0x80000000
  InitialSequenceNumber = N + 1
  MaxSequenceNumber = N - 1

  ROUTER_LINK_P2P = 1
  ROUTER_LINK_TRANSIT = 2
  ROUTER_LINK_STUB = 3
  ROUTER_LINK_VL = 4

  ROUTER_LSA = 1
  NETWORK_LSA = 2
  SUMMARY_LSA = 3
  ASBR_SUMMMARY_LSA = 4
  EXTERNAL_LSA = 5
  NSSA_LSA = 7

  IPPROTO_OSPF = 89
  AllSPFRouters = "224.0.0.5"
  AllDRouters = "224.0.0.6"

  EXTERNAL_BASE_ADDRESS='50.0.0.0/24'
  SUMMARY_BASE_ADDRESS='30.0.0.0/24'
  NETWORK_BASE_ADDRESS='20.0.0.0/24'
  LINK_BASE_ADDRESS='13.0.0.0/30'
  
  PACKET_HEADER_LEN = 24
  LSA_HEADER_LEN = 20
  
  
end