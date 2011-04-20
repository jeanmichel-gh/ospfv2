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

require 'ie/ie'
module OSPFv2
class LsType
  include IE

  @ls_type_junos = {
    1 => 'Router'  ,
    2 => 'Network' ,
    3 => 'Summary' ,
    4 => 'ASBRSum' ,
    5 => 'Extern'  ,
    9 => 'OpaqLoca',
    10=> 'OpaqArea',
    11=> 'OpaqAS'  ,
  }

  @ls_type_ios = {
    1 => 'Router Links',
    2 => 'Network Links',
    3 => 'Summary Links(Network)',
    4 => 'Summary Links(AS Boundary Router)',
    5 => 'AS External Link',
    9 => 'OpaqLoca',
    10=> 'Opaque Area Link',
    11=> 'OpaqAS'  ,
  }

  @ls_type_short = {
    1=>'router'   ,
    2=>'network'  ,
    3=>'summary'  ,
    4=>'asbrSum'  ,
    5=>'external' ,
    7=>'nssa'     ,
    9=>'opaqLnk'  ,
    10=>'opaqArea',
    11=>'opaqAs'  ,
  }

# FIXME: rename all opaque :opaque_area , :opaque_link_local, :opaque_domain
  @ls_type_sym = {
    1  => :router      ,
    2  => :network     ,
    3  => :summary     ,
    4  => :asbr_summary,
    5  => :as_external ,
    7  => :as_external7,
    9  => :link_local  ,
    10 => :area        ,
    11 => :domain      ,
  }
  
  @ls_type_sym_to_i = @ls_type_sym.invert
  
  def is_opaque?
    (9..11) === @ls_type
  end

  class << self
    def all
      [:router, :network, :summary, :asbr_summary, :as_external, :area]
    end

    def to_i(arg)
      return arg unless arg.is_a?(Symbol)
      ls_type_sym_to_i(arg)
      # case arg.to_s
      # when /^router(_lsa|)$/       ; @ls_type=1
      # when /^network(_lsa|)$/      ; @ls_type=2
      # when /^summary(_lsa|)$/      ; @ls_type=3
      # when /^asbr_summary(_lsa|)$/ ; @ls_type=4
      # when /^as_external(_lsa|)$/  ; @ls_type=5
      #   #FIXME: finish and unit-test
      #   # when :as_external7_lsa ; @ls_type=7
      #   # when :opaque_link      ; @ls_type=9
      #   # when :opaque_area      ; @ls_type=10
      #   # when :opaque_as        ; @ls_type=11
      # end    
    end

    def to_sym(arg)
      return arg unless arg.is_a?(Fixnum)
      if @ls_type_sym.has_key?(arg)
        @ls_type_sym[arg]
      else
        raise
      end
    end

    def ls_type_sym_to_i(arg)
      return arg if arg.is_a?(Fixnum)
      if @ls_type_sym_to_i.has_key?(arg)
        @ls_type_sym_to_i[arg]
      else
        raise "cannot convert #{arg.inspect} to i"
      end
    end

    def to_junos(arg)
      return arg unless arg.is_a?(Fixnum)
      if @ls_type_junos.has_key?(arg)
        @ls_type_junos[arg]
      else
        raise
      end
    end

    def to_s_ios(arg)
      return arg unless arg.is_a?(Fixnum)
      if @ls_type_ios.has_key?(arg)
        @ls_type_ios[arg]
      else
        raise
      end
    end

    def to_short(arg)
      return arg unless arg.is_a?(Fixnum)
      if @ls_type_short.has_key?(arg)
        @ls_type_short[arg]
      else
        raise
      end
    end
  end

  def initialize(ls_type=1)
    @ls_type = case ls_type
    when Symbol
      LsType.ls_type_sym_to_i(ls_type)
    when Fixnum
      ls_type
    else
      raise ArgumentError, "Invalid LsType #{ls_type}"
    end
  end
  def to_i
    @ls_type
  end
  def to_s
    self.class.to_s.split('::').last + ": #{to_sym}"
  end

  def to_sym
    LsType.to_sym @ls_type
  end

  def encode
    [@ls_type].pack('C')
  end
  alias :enc  :encode
  
  def to_hash
    to_sym
  end
  
  def to_s_short
    LsType.to_short(to_i)
  end
  
  def to_s_ios
    "LS Type: " + LsType.to_s_ios(to_i)
  end
  
  def to_junos
    LsType.to_junos(to_i)
  end
  
end
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0



