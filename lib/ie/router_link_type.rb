# Router Link:
# Type   Description
#  __________________________________________________
#  1      Point-to-point connection to another router
#  2      Connection to a transit network
#  3      Connection to a stub network
#  4      Virtual link

module OSPFv2
class RouterLinkType
  def self.each
    [:point_to_point, :transit_network, :stub_network, :virtual_link].each { |x| yield(x) } if block_given?
  end
  def self.to_i(arg)
    return arg unless arg.is_a?(Symbol)
    [:point_to_point, :transit_network, :stub_network, :virtual_link].index(arg)+1
  end
  def self.to_junos(type)
    case type.to_i
    when 1 ; 'Point-to-point'
    when 2 ; 'Transit'
    when 3 ; 'Stub'
    when 4 ; 'Virtual-link'
    else   ; type.to_i 
    end
  end
  def initialize(router_link_type=1)
    case router_link_type
    when  1, :point_to_point   ; @router_link_type=1
    when  2, :transit_network  ; @router_link_type=2
    when  3, :stub_network     ; @router_link_type=3
    when  4, :virtual_link     ; @router_link_type=4
    else
      raise ArgumentError, "Invalid RouterLinkType #{router_link_type}"
    end
  end
  def to_i
    @router_link_type
  end
  def to_s
    self.class.to_s.split('::').last + ": #{to_sym}"
  end
  def to_sym
    case @router_link_type
    when 1  ; :point_to_point
    when 2  ; :transit_network
    when 3  ; :stub_network
    when 4  ; :virtual_link
    end
  end
  def encode
    [@router_link_type].pack('C')
  end
  alias :enc  :encode
  
  def to_hash
    to_sym
  end
  
end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

