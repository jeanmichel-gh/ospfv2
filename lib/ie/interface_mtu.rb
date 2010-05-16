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
require 'infra/ospf_constants'

module OSPFv2

class InterfaceMtu
  include Common
  
  attr_checked :interface_mtu do |x|
    (0..0xffff).include?(x)
  end
  
  def initialize(interface_mtu=1500)
    self.interface_mtu=interface_mtu
  end
  
  def to_i
    interface_mtu
  end
  
  def number_of_lsa
    @noh ||= ((to_i - OSPFv2::PACKET_HEADER_LEN) / OSPFv2::LSA_HEADER_LEN) - 1
  end
  alias :n0flsa :number_of_lsa
  
  def to_s
    self.class.to_s.split('::').last + ": #{to_i}"
  end
  
  def encode(fmt='n')
    [interface_mtu].pack(fmt)
  end
  alias :enc  :encode
  
  def to_hash
    to_i
  end
  
end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
