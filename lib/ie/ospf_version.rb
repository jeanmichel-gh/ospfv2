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
class OspfVersion
  def initialize(version=2)
    case version
    when :v2, 2 ; @ospf_version = 2
    when :v3, 3 ; @ospf_version = 3
    else
      @ospf_version = 0
    end
  end
  def to_s
    case @ospf_version
    when 2  ; '2'
    when 3  ; '3'
    else
      'unknown'
    end
  end
  def to_hash
    to_i
  end
  def to_i
    @ospf_version
  end
  def to_s
    self.class.to_s.split('::').last + ": #{to_sym}"
  end
  def to_sym
    case @ospf_version
    when 2  ; :v2
    when 3  ; :v3
    else
      ':v?'
    end
  end

  def encode
    [@ospf_version].pack('C')
  end
  alias :enc  :encode
  
end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
