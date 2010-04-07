require 'set'
require 'ie/id'

module OSPFv2::LSDB
  class AdvertisedRouters
    AdvertisedRouter = Class.new(OSPFv2::Id)
    attr_reader :routers
    def initialize
      @set = Set.new
    end
    def +(id)
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

if __FILE__ == $0

  require "test/unit"

  # require "ls_db/advertised_routers"

  class TestLsDbAdvertisedRouters < Test::Unit::TestCase
    include OSPFv2::LSDB
    def tests
      assert AdvertisedRouters.new
      routers = AdvertisedRouters.new
      routers + 1
      routers + '0.0.0.1'
      routers + 2
      routers + OSPFv2::Id.new(3)
      assert_equal [1,2,3], routers.routers
      routers -1 
      assert_equal [2,3], routers.routers
      routers -3
      assert_equal [2], routers.routers
      routers - '0.0.0.2'
      assert_equal [], routers.routers
    end
  end

end

__END__



@advertised_routers << id2ip(rid)