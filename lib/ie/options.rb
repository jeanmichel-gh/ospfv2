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


=begin rdoc
    
A.2 The Options field

   The 24-bit OSPF Options field is present in OSPF Hello packets,
   Database Description packets and certain LSAs (router-LSAs, network-
   LSAs, inter-area-router-LSAs and link-LSAs). The Options field
   enables OSPF routers to support (or not support) optional
   capabilities, and to communicate their capability level to other OSPF
   routers.  Through this mechanism routers of differing capabilities
   can be mixed within an OSPF routing domain.

   An option mismatch between routers can cause a variety of behaviors,
   depending on the particular option. Some option mismatches prevent
   neighbor relationships from forming (e.g., the E-bit below); these
   mismatches are discovered through the sending and receiving of Hello
   packets. Some option mismatches prevent particular LSA types from
   being flooded across adjacencies (e.g., the MC-bit below); these are
   discovered through the sending and receiving of Database Description
   packets. Some option mismatches prevent routers from being included
   in one or more of the various routing calculations because of their
   reduced functionality (again the MC-bit is an example); these
   mismatches are discovered by examining LSAs.

   Six bits of the OSPF Options field have been assigned. Each bit is
   described briefly below. Routers should reset (i.e.  clear)
   unrecognized bits in the Options field when sending Hello packets or
   Database Description packets and when originating LSAs. Conversely,
   routers encountering unrecognized Option bits in received Hello
   Packets, Database Description packets or LSAs should ignore the
   capability and process the packet/LSA normally.


                             1                     2
         0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8  9  0  1  2  3
        -+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+--+--+--+--+--+--+
         | | | | | | | | | | | | | | | | | |DC| R| N|MC| E|V6|
        -+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+--+--+--+--+--+--+

                        The Options field

   V6-bit
     If this bit is clear, the router/link should be excluded from IPv6
     routing calculations. See Section 3.8 of this memo.

   E-bit
     This bit describes the way AS-external-LSAs are flooded, as
     described in Sections 3.6, 9.5, 10.8 and 12.1.2 of [Ref1].

   MC-bit
     This bit describes whether IP multicast datagrams are forwarded
     according to the specifications in [Ref7].

   N-bit
     This bit describes the handling of Type-7 LSAs, as specified in
     [Ref8].

   R-bit
     This bit (the `Router' bit) indicates whether the originator is an
     active router.  If the router bit is clear routes which transit the
     advertising node cannot be computed. Clearing the router bit would
     be appropriate for a multi-homed host that wants to participate in
     routing, but does not want to forward non-locally addressed
     packets.

   DC-bit
     This bit describes the router's handling of demand circuits, as
     specified in [Ref10].


2.1.  L-bit in Options Field

   A new L bit (L stands for LLS) is introduced into the OSPF Options
   field (see Figure 2a/2b).  Routers set the L bit in Hello and DD
   packets to indicate that the packet contains an LLS data block.  In
   other words, the LLS data block is only examined if the L bit is set.

              +---+---+---+---+---+---+---+---+
              | * | O | DC| L |N/P| MC| E | * |
              +---+---+---+---+---+---+---+-+-+

               Figure 2a: OSPFv2 Options field




=end

require 'infra/ospf_common'
module OSPFv2
  
  
  class Options
     
    attr_accessor :options

    def initialize(arg={})
      @options=0
      if arg.is_a?(Hash) then
        set(arg)
      elsif arg.is_a?(String)
        _parse_(arg)
      elsif arg.is_a?(Fixnum) and (0..255) === arg
        @options = arg
      elsif arg.is_a?(self.class)
        set(arg.to_hash)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end
    
    def set(arg)
      return self unless arg.is_a?(Hash)
      
      unless arg[:O].nil? and arg[:o].nil?
        _flag = arg[:O] ||= arg[:o]
        if _flag.is_a?(TrueClass)
          setO
        elsif _flag.is_a?(FalseClass)
          unsetO
        elsif _flag.is_a?(Fixnum)
          if _flag == 0
            unsetO
          else
            setO
          end
        end
      end
      unless arg[:DC].nil? and arg[:dc].nil?
        _flag = arg[:DC] ||= arg[:dc]
        if _flag.is_a?(TrueClass)
          setDC
        elsif _flag.is_a?(FalseClass)
          unsetDC
        elsif _flag.is_a?(Fixnum)
          if _flag == 0
            unsetDC
          else
            setDC
          end
        end
      end
      unless arg[:L].nil? and arg[:l].nil?
        _flag = arg[:L] ||= arg[:l]
        if _flag.is_a?(TrueClass)
          setL
        elsif _flag.is_a?(FalseClass)
          unsetL
        elsif _flag.is_a?(Fixnum)
          if _flag == 0
            unsetL
          else
            setL
          end
        end
      end
      unless arg[:N].nil? and arg[:n].nil?
        _flag = arg[:N] ||= arg[:n]
        if _flag.is_a?(TrueClass)
          setN
        elsif _flag.is_a?(FalseClass)
          unsetN
        elsif _flag.is_a?(Fixnum)
          if _flag == 0
            unsetN
          else
            setN
          end
        end
      end
      unless arg[:P].nil? and arg[:p].nil?
        _flag = arg[:P] ||= arg[:p]
        if _flag.is_a?(TrueClass)
          setP
        elsif _flag.is_a?(FalseClass)
          unsetP
        elsif _flag.is_a?(Fixnum)
          if _flag == 0
            unsetP
          else
            setP
          end
        end
      end
      unless arg[:MC].nil? and arg[:mc].nil?
        _flag = arg[:MC] ||= arg[:mc]
        if _flag.is_a?(TrueClass)
          setMC
        elsif _flag.is_a?(FalseClass)
          unsetMC
        elsif _flag.is_a?(Fixnum)
          if _flag == 0
            unsetMC
          else
            setMC
          end
        end
      end
      unless arg[:E].nil? and arg[:e].nil?
        _flag = arg[:E] ||= arg[:e]
        if _flag.is_a?(TrueClass)
          setE
        elsif _flag.is_a?(FalseClass)
          unsetE
        elsif _flag.is_a?(Fixnum)
          if _flag == 0
            unsetE
          else
            setE
          end
        end
      end
      unless arg[:V6].nil? and arg[:v6].nil?
        _flag = arg[:V6] ||= arg[:v6]
        if _flag.is_a?(TrueClass)
          setV6
        elsif _flag.is_a?(FalseClass)
          unsetV6
        elsif _flag.is_a?(Fixnum)
          if _flag == 0
            unsetV6
          else
            setV6
          end
        end
      end
      self
    end
    
    def __setBit(bit)
      @options = @options | (2 ** (bit-1))
    end
    private :__setBit
    def __unsetBit(bit)
      @options = @options & ~(2 ** (bit-1))
    end
    private :__unsetBit
    def __isSet(bit)
      @options & (2**(bit-1))>0 
    end
    private :__isSet
    
    def setO    ; __setBit(7)   ; end
    def unsetO  ; __unsetBit(7) ; end
    def o?      ; __isSet(7)    ; end

    def setDC   ; __setBit(6)   ; end
    def unsetDC ; __unsetBit(6) ; end
    def dc?     ; __isSet(6)    ; end
    
    # A new L-bit (L stands for LLS) is introduced into the OSPF Options
    # field (see Figures 2a and 2b).  Routers set the L-bit in Hello and DD
    # packets to indicate that the packet contains an LLS data block.  In
    # other words, the LLS data block is only examined if the L-bit is set.
    def setL    ; __setBit(5)   ; end
    def unsetL  ; __unsetBit(5) ; end
    def l?      ; __isSet(5)    ; end
    
    # N-bit is used in Hello packets only. 
    # It signals the area is an NSSA area.
    def setN    ; __setBit(4)   ; end
    def unsetN  ; __unsetBit(4) ; end
    def n?      ; __isSet(4)    ; end

    # P-bit is used in Type-7 LSA Header
    # It signals the NSSA border to translate the Type-7 into Type-5.
    def setP    ; __setBit(4)   ; end
    def unsetP  ; __unsetBit(4) ; end
    def p?      ; __isSet(4)    ; end
    
    def setMC   ; __setBit(3)   ; end
    def unsetMC ; __unsetBit(3) ; end
    def mc?     ; __isSet(3)    ; end
    
    def setE    ; __setBit(2)   ; end
    def unsetE  ; __unsetBit(2) ; end
    def e?      ; __isSet(2)    ; end
    
    def setV6   ; __setBit(1)   ; end
    def unsetV6 ; __unsetBit(1) ; end
    def v6?     ; __isSet(1)    ; end
    
    def setNSSA
      setN
      unsetE
    end
    
    def encode
      [@options].pack('C')
    end
    
    def _parse_(s)
      @options = s.unpack('C')[0]
    end
    private :_parse_

    # V6-bit
    #   If this bit is clear, the router/link should be excluded from IPv6
    #   routing calculations. See Section 3.8 of this memo.
    # 
    # E-bit
    #   This bit describes the way AS-external-LSAs are flooded, as
    #   described in Sections 3.6, 9.5, 10.8 and 12.1.2 of [Ref1].
    # 
    # MC-bit
    #   This bit describes whether IP multicast datagrams are forwarded
    #   according to the specifications in [Ref7].
    # 
    # N-bit
    #   This bit describes the handling of Type-7 LSAs, as specified in
    #   [Ref8].
    # 
    # R-bit
    #   This bit (the `Router' bit) indicates whether the originator is an
    #   active router.  If the router bit is clear routes which transit the
    #   advertising node cannot be computed. Clearing the router bit would
    #   be appropriate for a multi-homed host that wants to participate in
    #   routing, but does not want to forward non-locally addressed
    #   packets.
    # 
    # DC-bit
    #   This bit describes the router's handling of demand circuits, as
    #   specified in [Ref10].
    def to_s
      self.class.to_s.split('::').last + ": " + format(' 0x%x  [%s]', to_i, _to_s_)   #[@options].pack('C').unpack('B8')[0][1..7]
    end

    def to_i
      @options
    end

    def to_hash
      to_i
    end
    
    private
    
    def _to_s_
      s = []
      s << 'O' if o?
      s << 'L' if l?
      s << 'DC' if dc?
      s << 'N' if n?
      s << 'MC' if mc?
      s << 'E' if e?
      s << 'V6' if v6?
      s.join(',')
    end

  end
  
end

load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
