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

require 'infra/ospf_constants'

module OSPFv2

  class SequenceNumber
    include OSPFv2
    include Comparable
    
    def SequenceNumber.initial
      [N + 1].pack('I').unpack('i')[0]
    end
    
    def SequenceNumber.max
      [N - 1].pack('I').unpack('i')[0]
    end
    
    def SequenceNumber.N
      [N].pack('I').unpack('i')[0]
    end
    
    def SequenceNumber.to_s(seqn)
      new(seqn).to_s
    end
    
    def initialize(seqn=:init)
      if seqn.is_a?(Symbol)
        if seqn == :max
          @seqn= MaxSequenceNumber
        elsif seqn == :init
          @seqn = InitialSequenceNumber
        elsif seqn == :reserved
          @seqn = N
        end 
      elsif seqn.is_a?(self.class)
        @seqn = seqn.to_I
      else
        @seqn=seqn
      end
      @seqn = [@seqn].pack('I')
    end

    def <=>(o)
      to_i <=> o.to_i
    end

    def to_i
      @seqn.unpack('i')[0]
    end
    def to_I
      @seqn.unpack('I')[0]
    end

    def to_s
      "0x"+ sprintf("%08.8x", to_I)
    end
    
    def +(num)
      seqn = (@seqn.unpack('i')[0]+num)
      @seqn = [seqn].pack('I')
      self
    end
    
    def incr
      +(1)
    end
    
    def -(num)
      self.+(-num)
    end
    
    def encode
      #FIXME: unit-test and check if 'i' or 'I'
      [to_i].pack('N')
    end
    
    def to_hash
      to_I
    end
    
  end

end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__


=begin rdoc
12.1.6.  LS sequence number

The sequence number field is a signed 32-bit integer.  It is
used to detect old and duplicate LSAs.  The space of
sequence numbers is linearly ordered.  The larger the
sequence number (when compared as signed 32-bit integers)
the more recent the LSA.  To describe to sequence number
space more precisely, let N refer in the discussion below to
the constant 2**31.

The sequence number -N (0x80000000) is reserved (and
unused).  This leaves -N + 1 (0x80000001) as the smallest
(and therefore oldest) sequence number; this sequence number
is referred to as the constant InitialSequenceNumber. A
router uses InitialSequenceNumber the first time it
originates any LSA.  Afterwards, the LSA's sequence number
is incremented each time the router originates a new
instance of the LSA.  When an attempt is made to increment
the sequence number past the maximum value of N - 1
(0x7fffffff; also referred to as MaxSequenceNumber), the
current instance of the LSA must first be flushed from the
routing domain.  This is done by prematurely aging the LSA
(see Section 14.1) and reflooding it.  As soon as this flood
has been acknowledged by all adjacent neighbors, a new
instance can be originated with sequence number of
InitialSequenceNumber.

The router may be forced to promote the sequence number of
one of its LSAs when a more recent instance of the LSA is
unexpectedly received during the flooding process.  This
should be a rare event.  This may indicate that an out-of-
date LSA, originated by the router itself before its last
restart/reload, still exists in the Autonomous System.  For
more information see Section 13.4.


=end
