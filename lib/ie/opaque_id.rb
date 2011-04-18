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

require 'infra/ospf_common'

module OSPFv2
class OpaqueId
  include Common
  
  attr_reader  :opaque_id
  attr_checked :opaque_id do |x|
    (0..0xffffff).include?(x)
  end
  
  def initialize(opaque_id=0)
    self.opaque_id=opaque_id
  end
  
  def to_i
    opaque_id
  end
  
  def to_s
    self.class.to_s.split('::').last + ": #{to_i}"
  end
  
  def encode
    [opaque_id].pack('N')[1..-1]
  end
  alias :enc  :encode
  
  def to_hash
    to_i
  end
  
end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0