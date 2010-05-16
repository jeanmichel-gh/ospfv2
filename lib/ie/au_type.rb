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


# 0 Null authentication 1 Simple password 2 Cryptographic authentication
module OSPFv2
class AuType
  def initialize(au_type=0)
    @au_type=0
    case au_type
    when :null, 0            ; @au_type = 0
    when :simple_password, 1 ; @au_type = 1
    when :cryptographic, 2   ; @au_type = 2
    else
      @au_type = au_type if au_type.is_a?(Integer)
    end
  end

  def to_hash
    to_sym
  end
  
  def to_i
    @au_type
  end
  
  def to_s
    self.class.to_s.split('::').last + ": #{au_to_s}"
  end
  
  def to_sym
    case @au_type
    when 2  ; :cryptographic
    when 1  ; :simple_password
    when 0  ; :null
    else
      :undefined?
    end
  end

  def encode
    [@au_type].pack('n')
  end
  alias :enc  :encode
  
  private

  def au_to_s
    case @au_type
    when 0 ; 'null authentication'
    when 1 ; 'simple password'
    when 2 ; 'cryptographic authentication'
    else
      'unknown'
    end
  end
  

end
end
