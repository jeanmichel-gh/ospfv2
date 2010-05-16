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
class PacketType
  def initialize(value=0)
    case value
    when 1, :hello      ; @packet_type = 1
    when 2, :dd         ; @packet_type = 2
    when 3, :ls_request ; @packet_type = 3
    when 4, :ls_update  ; @packet_type = 4
    when 5, :ls_ack     ; @packet_type = 5
    else
      @packet_type = 0
    end
  end
  def to_hash
    to_sym
  end
  def to_i
    @packet_type
  end
  def to_s
    self.class.to_s.split('::').last + ": #{to_sym}"
  end
  def to_sym
    case @packet_type
    when 1  ; :hello
    when 2  ; :dd
    when 3  ; :ls_request
    when 4  ; :ls_update
    when 5  ; :ls_ack
    else
      'unknown'
    end
  end

  def encode
    [@packet_type].pack('C')
  end
  alias :enc  :encode
  
end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
