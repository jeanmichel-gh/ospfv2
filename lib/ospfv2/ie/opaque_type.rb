#--
# Copyright 2011 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
#++

require_relative './ie'
module OSPFv2
class OpaqueType
  include IE
  
  @opaque_type_sym = {
    1  => :te_lsa,
    2  => :sycamore_optical_topology_description,
    3  => :grace_lsa,
    4  => :router_information,
    7  => :extended_prefix,     # RFC 7684 section 2
    8  => :extended_link,       # RFC 7684 section 3
  }
  
  @opaque_type_sym_to_i = @opaque_type_sym.invert
  
  class << self
    def all
      @opaque_type_sym_to_i.key
    end
    
    # An opaque type with no name gives its number: the simulator keeps
    # opaque LSAs of any type (OpaqueLsa).
    def to_sym(arg)
      return arg unless arg.is_a?(Integer)
      @opaque_type_sym.fetch(arg, arg)
    end
    
    def to_i(arg)
      return arg if arg.is_a?(Integer)
      if @opaque_type_sym_to_i.has_key?(arg)
        @opaque_type_sym_to_i[arg]
      else
        raise
      end
    end
    
  end
  
  def initialize(opaque_type=1)
    @opaque_type = case opaque_type
    when Symbol
      OpaqueType.to_i(opaque_type)
    when Integer
      opaque_type
    else
      raise ArgumentError, "Invalid OpaqueType #{opaque_type}"
    end
  end
  def to_i
    @opaque_type
  end
  def to_s
    self.class.to_s.split('::').last + ": #{to_sym}"
  end

  def to_sym
    OpaqueType.to_sym @opaque_type
  end

  def encode
    [@opaque_type].pack('C')
  end
  alias :enc  :encode
  
  def to_hash
    to_sym
  end
  
end
end


__END__

Registry:
Value    Opaque Type                                 Reference
-------  ------------------------------------------  ---------
1        Traffic Engineering LSA                     [RFC3630]
2        Sycamore Optical Topology Descriptions      [Moy]
3        grace-LSA                                   [RFC3623]
4        Router Information (RI)                     [RFC4970]
5-127    Unassigned
128-255  Private Use

