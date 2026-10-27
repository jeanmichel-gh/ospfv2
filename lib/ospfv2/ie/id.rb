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


require 'ipaddr'
require_relative '../infra/ospf_common'
require_relative 'ie'

module OSPFv2
class Id
  include IE

  def self.new_ntoh(s)
    return unless s.is_a?(String)
    new s.unpack('N')[0]
  end

  def self.to_i(id)
    return id.to_i unless id.is_a?(String) and id.split('.').size==4
    IPAddr.new(id).to_i
  end

  def initialize(arg=0)
    self.id = arg
  end
  
  def id=(val)
    if val.is_a?(Hash)
      @id = val[:id] if val[:id]
    elsif val.is_a?(IPAddr)
      @id = val.to_i
    elsif val.is_a?(Integer)
      raise ArgumentError, "Invalid Argument #{val}" unless (0..0xffffffff).include?(val)
      @id = val
    elsif val.is_a?(String)
      @id = IPAddr.new(val).to_i
    elsif val.is_a?(Id)
      @id = val.to_i
    else
      raise ArgumentError, "Invalid Argument #{val.inspect}"
    end
  end
  
  def encode
    [@id].pack('N')
  end
  alias :enc  :encode

  def to_i
    @id
  end
  
  def to_s(verbose=true)
    verbose ? to_s_verbose : to_s_short
  end
  
  def to_hash
    to_s_short
  end

  def to_ip
    to_s(false)
  end
  
  private
  
  def to_s_short
    IPAddr.new_ntoh([@id].pack('N')).to_s
  end
  
  def to_s_verbose
    self.class.to_s.split('::').last + ": " + to_s_short
  end
  
end

end
