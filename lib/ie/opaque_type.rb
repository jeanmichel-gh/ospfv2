#--
# Copyright 2011 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of OSPFv2.
# 
#++

require 'ie/ie'
module OSPFv2
class OpaqueType
  include IE
  
  @opaque_type_sym = {
    1  => :te_lsa,
    2  => :sycamore_optical_topology_description,
    3  => :grace_lsa,
    4  => :router_information,
  }
  
  @opaque_type_sym_to_i = @opaque_type_sym.invert
  
  class << self
    def all
      @opaque_type_sym_to_i.key
    end
    
    def to_sym(arg)
      return arg unless arg.is_a?(Fixnum)
      if @opaque_type_sym.has_key?(arg)
        @opaque_type_sym[arg]
      else
        raise
      end
    end
    
    def to_i(arg)
      return arg if arg.is_a?(Fixnum)
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
    when Fixnum
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

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

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

