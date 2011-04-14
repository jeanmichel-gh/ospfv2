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

require 'set'
require 'ie/id'

module OSPFv2::LSDB
  class AdvertisedRouters
    AdvertisedRouter = Class.new(OSPFv2::Id)
    def initialize
      @set = Set.new
    end
    def <<(id)
      @set << router_id(id)
    end
    def routers
      @set.collect.sort
    end
    alias :ids :routers
    def has?(id)
      routers.include?(router_id(id))
    end
    def -(id)
      @set.delete router_id(id)
    end
    private
    def router_id(id)
      AdvertisedRouter.new(id).to_i
    end
  end
end

# if __FILE__ == $0
# 
#   require "test/unit"
# 
#   # require "ls_db/advertised_routers"
# 
#   class TestLsDbAdvertisedRouters < Test::Unit::TestCase
#     include OSPFv2::LSDB
#     def tests
#       assert AdvertisedRouters.new
#       routers = AdvertisedRouters.new
#       routers + 1
#       routers + '0.0.0.1'
#       routers + 2
#       routers + OSPFv2::Id.new(3)
#       assert_equal [1,2,3], routers.routers
#       routers -1 
#       assert_equal [2,3], routers.routers
#       routers -3
#       assert_equal [2], routers.routers
#       routers - '0.0.0.2'
#       assert_equal [], routers.routers
#     end
#   end
# 
# end
