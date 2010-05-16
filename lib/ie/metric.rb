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

class Metric
  include Common
  
  attr_reader  :metric
  attr_checked :metric do |x|
    (0..0xffffff).include?(x)
  end
  
  def initialize(metric=0)
    self.metric=metric
  end
  
  def to_i
    metric
  end
  
  def to_s
    self.class.to_s.split('::').last + ": #{to_i}"
  end
  
  def to_s_junos
    "Topology default (ID 0) -> Metric: #{to_i}"
  end
  
  def encode(fmt='N')
    [metric].pack(fmt)
  end
  alias :enc  :encode
  
  def to_hash
    to_i
  end
  
end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
