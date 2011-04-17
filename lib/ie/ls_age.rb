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

require 'infra/ospf_constants'

module OSPFv2
class LsAge
  
  class << self
    attr_accessor :_aging
    def aging?
      _aging
    end
    def aging(arg=nil)
      if arg
        case arg
        when :on  ; self._aging = true
        when :off ; self._aging = false
        end
      else
        self._aging = ! _aging
      end
    end
  end
  
  include Comparable
  
  def initialize(age=0)
    @age=age
    raise ArgumentError, "Invalid Argument #{age}" unless age.is_a?(Integer)
  end
  
  def to_i
    if aging?
      @time ||= Time.now
      (Time.new - @time + @age).to_int
    else
      @age
    end
  end
  
  def reset(age=nil)
    @age = age if age
    @time=nil
  end
  
  def aging?
    self.class.aging?
  end
  
  def maxage
    @age = OSPFv2::MaxAge
  end
  
  def maxaged?
    to_i >= OSPFv2::MaxAge
  end
  
  def <=>(obj)
    to_i <=> obj.to_i
  end
  
  def -(obj)
    to_i - obj.to_i
  end
  
  def to_s
    self.class.to_s.split('::').last + ": #{to_i}"
  end
  
  def to_s_ios
    "LS age: #{to_i}"
  end
  
  def encode
    [@age].pack('n')
  end
  alias :enc  :encode
  
  def to_hash
    to_i
  end
  
end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
