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

# Router Link:
# Type   Description
#  __________________________________________________
#  1      Point-to-point connection to another router
#  2      Connection to a transit network
#  3      Connection to a stub network
#  4      Virtual link

module OSPFv2
class RouterLinkType

  @router_link_sym = {
    1  => :point_to_point,
    2  => :transit_network,
    3  => :stub_network,
    4  => :virtual_link,
  }
  
  @router_link_sym_to_i = @router_link_sym.invert
  
  @router_link_type_junos = {
    1 => 'Point-to-point',
    2 => 'Transit',
    3 => 'Stub',
    4 => 'Virtual-link',
  }

  @router_link_type_ios = {
    1 => 'another Router (point-to-point)',
    2 => 'a Transit Network',
    3 => 'a Stub Network',
    4 => 'a Virtual Link',
  }
  
  @link_id_from_type = {
    1 => 'Neighboring Router ID',
    2 => 'Designated Router address',
    3 => 'Network/subnet number',
    4 => 'TBD',
  }

  @link_data_from_type = {
    1 => 'Router Interface address',
    2 => 'Router Interface address',
    3 => 'Network Mask',
    4 => 'TBD',
  }

  class << self

    def to_i(arg)
      router_link_sym_to_i(arg)
    end
    
    def all
      [:point_to_point, :transit_network, :stub_network, :virtual_link]
    end
    
    def each
      all.each { |x| yield(x) } if block_given?
    end

    def to_sym(arg)
      return arg unless arg.is_a?(Integer)
      if @router_link_sym.has_key?(arg)
        @router_link_sym[arg]
      else
        raise
      end
    end

    def router_link_sym_to_i(arg)
      return arg if arg.is_a?(Integer)
      if @router_link_sym_to_i.has_key?(arg)
        @router_link_sym_to_i[arg]
      else
        raise
      end
    end
    
    def link_id_to_s(arg)
      return arg unless arg.is_a?(Integer)
      if @link_id_from_type.has_key?(arg)
        @link_id_from_type[arg]
      else
        raise
      end
    end
    
    def link_data_to_s(arg)
      return arg unless arg.is_a?(Integer)
      if @link_data_from_type.has_key?(arg)
        @link_data_from_type[arg]
      else
        raise
      end
    end

    def to_junos(arg)
      return arg unless arg.is_a?(Integer)
      if @router_link_type_junos.has_key?(arg)
        @router_link_type_junos[arg]
      else
        arg
      end
    end

    def to_s_ios(arg)
      return arg unless arg.is_a?(Integer)
      if @router_link_type_ios.has_key?(arg)
        @router_link_type_ios[arg]
      else
        arg
      end
    end
  end

  def initialize(arg=1)
    @router_link_type = case arg
    when Symbol
      self.class.router_link_sym_to_i(arg)
    when Integer
      arg
    else
      raise ArgumentError, "Invalid RouterLinkType #{arg}"
    end
  end
  def to_i
    @router_link_type
  end
  def to_s
    self.class.to_s.split('::').last + ": #{to_sym}"
  end
  def to_s_ios
    RouterLinkType.to_s_ios to_i
  end
  def to_sym
    RouterLinkType.to_sym @router_link_type
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

