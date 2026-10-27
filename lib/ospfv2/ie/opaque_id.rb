#--
# Copyright 2011 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
#++

require_relative '../infra/ospf_common'

module OSPFv2
class OpaqueId
  include Common
  
  attr_reader  :opaque_id
  extend OSPFv2::Attributes
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

