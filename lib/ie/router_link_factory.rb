require 'infra/ospf_common'
require 'ie/router_link'

module OSPFv2
  class RouterLink
    def self.factory(arg)
      if arg.is_a?(Hash)
        raise ArgumentError, "no link type specified" unless  arg[:router_link_type]
        case arg[:router_link_type]
        when 1,:point_to_point  ; PointToPoint.new(arg)
        when 2,:transit_network ; TransitNetwork.new(arg)
        when 3,:stub_network    ; StubNetwork.new(arg)
        when 4,:virtual_link    ; VirtualLink.new(arg)
        end
      elsif arg.is_a?(String)
        case arg[8,1].unpack('C')[0]
        when 1 ; PointToPoint.new(arg)
        when 2 ; TransitNetwork.new(arg)
        when 3 ; StubNetwork.new(arg)
        when 4 ; VirtualLink.new(arg)
        else
          raise ArgumentError, "Invalid Argument: #{arg[8,1].unpack('C')[0]} #{arg.inspect}/#{arg.unpack('H*')}"
        end
      elsif arg.is_a?(RouterLink)
        factory(arg.encode)
      end
    end
  end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
