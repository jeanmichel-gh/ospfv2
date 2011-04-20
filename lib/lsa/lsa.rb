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
  
A.4.1 The LSA header

All LSAs begin with a common 20 byte header.  This header contains
enough information to uniquely identify the LSA (LS type, Link State
ID, and Advertising Router).  Multiple instances of the LSA may
exist in the routing domain at the same time.  It is then necessary
to determine which instance is more recent.  This is accomplished by
examining the LS age, LS sequence number and LS checksum fields that
are also contained in the LSA header.


  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |            LS age             |    Options    |    LS type    |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |                        Link State ID                          |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |                     Advertising Router                        |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |                     LS sequence number                        |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |         LS checksum           |             length            |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+


  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |            LS age             |     Options   |  9, 10, or 11 |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |  Opaque Type  |               Opaque ID                       |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Advertising Router                       |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      LS Sequence Number                       |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |         LS checksum           |           Length              |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                                                               |
  +                                                               +
  |                      Opaque Information                       |
  +                                                               +
  |                              ...                              |
 # 



LS age
    The time in seconds since the LSA was originated.

Options
    The optional capabilities supported by the described portion of
    the routing domain.  OSPF's optional capabilities are documented
    in Section A.2.

LS type
    The type of the LSA.  Each LSA type has a separate advertisement
    format.  The LSA types defined in this memo are as follows (see
    Section 12.1.3 for further explanation):


                    LS Type   Description
                    ___________________________________
                    1         Router-LSAs
                    2         Network-LSAs
                    3         Summary-LSAs (IP network)
                    4         Summary-LSAs (ASBR)
                    5         AS-external-LSAs


Link State ID
    This field identifies the portion of the internet environment
    that is being described by the LSA.  The contents of this field
    depend on the LSA's LS type.  For example, in network-LSAs the
    Link State ID is set to the IP interface address of the
    network's Designated Router (from which the network's IP address
    can be derived).  The Link State ID is further discussed in
    Section 12.1.4.

Advertising Router
    The Router ID of the router that originated the LSA.  For
    example, in network-LSAs this field is equal to the Router ID of
    the network's Designated Router.

LS sequence number
    Detects old or duplicate LSAs.  Successive instances of an LSA
    are given successive LS sequence numbers.  See Section 12.1.6
    for more details.

LS checksum
    The Fletcher checksum of the complete contents of the LSA,
    including the LSA header but excluding the LS age field. See
    Section 12.1.7 for more details.

length
    The length in bytes of the LSA.  This includes the 20 byte LSA
    header.

=end

require 'infra/ospf_common'
require 'infra/ospf_constants'
require 'ie/id'
require 'ie/ls_type'
require 'ie/ls_age'
require 'ie/sequence_number'
require 'ie/options'
require 'ls_db/advertised_routers'

module OSPFv2
  
  class Lsa
    include Comparable
    
    unless const_defined?(:AdvertisingRouter)
      AdvertisingRouter = Class.new(Id) do
        def to_s_ios
          "Advertising Router: " + to_ip
        end
      end
      LsId = Class.new(Id) do
        def to_s_ios
          "Link State ID: " + to_ip
        end
      end
      LsAge = Class.new(LsAge)
      MODX=4102
    end
    
    
    #  0                   1                   2                   3
    #  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |            LS age             |    Options    |    LS type    |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |                        Link State ID                          |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |                     Advertising Router                        |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |                     LS sequence number                        |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |         LS checksum           |             length            |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # 
    class Header
    end
    

    #FIXME: need to generate Router, Network, .. LSAs.
    class << self
      def new_ntop(arg)
        lsa = new
        if arg.is_a?(String)
          lsa.parse(arg)
        elsif arg.is_a?(self)
          lsa.parse arg.encode
        else
          raise ArgumentError, "Invalid Argument: #{arg.inspect}"
        end
        lsa
      end
    end
    
    include OSPFv2::Common
    include OSPFv2::Constant
    
    # FIXME: when adding LSA in LSDB should be acked when init, rxmt otherwise ....
    def ack
      @_rxmt_=false
    end
    def retransmit
      @_rxmt_=true
    end
    def is_acked?
      @_rxmt_ == false
    end
    alias :acked? :is_acked?
    alias :ack? :acked?
    
    attr_reader :ls_age, :options
    attr_reader :ls_id
    attr_reader :advertising_router
    attr_reader :sequence_number
    attr_reader :opaque_id, :opaque_type
    
    attr_writer_delegate :advertising_router, :ls_id, :ls_age, :opaque_id, :opaque_type
    
    LsType.all.each do |type|
      define_method("#{type}?") do
        type == LsType.to_sym(@ls_type.to_i)
      end
    end
    
    def initialize(arg={})
      arg = arg.dup
      
      @ls_age = LsAge.new
      @sequence_number = SequenceNumber.new
      @options = Options.new
      @ls_id = LsId.new
      @ls_id = nil
      if is_opaque?
        @opaque_id   = OpaqueId.new
        @opaque_type = OpaqueType.new
      else
        @ls_id=LsId.new
      end
      @advertising_router = AdvertisingRouter.new
      @_length = 0
      @_rxmt_ = false
      
      if arg.is_a?(Hash)
        set arg
      elsif arg.is_a?(String)
        parse arg
      elsif arg.is_a?(self.class)
        parse arg.encode
      else        
        raise ArgumentError, "Invalid Argument: #{arg.inspect}"
      end
      
    end
    
    def ls_type
      @ls_type ||= LsType.new(1)
    end
    
    def sequence_number=(seqn)
      @sequence_number = SequenceNumber.new(seqn)
    end

    def to_s_ios
      sprintf("%-15.15s %-15.15s %-4.0d        0x%8.8X 0x%6.6X ", 
            is_opaque? ? ls_id = Id.new_ntoh(@opaque_type.encode + @opaque_id.encode).to_ip : self.ls_id.to_ip, 
            advertising_router.to_ip, 
            ls_age.to_i, 
            seqn.to_I, 
            csum_to_i)
    end

    def to_s
      len = encode.size
      if is_opaque?
        ls_id = Id.new_ntoh(@opaque_type.encode + @opaque_id.encode)
        sprintf("%-4.0d  0x%2.2x  %-8s  %-15.15s %-15.15s 0x%8.8x  0x%4.4x   %-7d", 
        ls_age.to_i, options.to_i, ls_type.to_s_short, ls_id.to_ip, advertising_router.to_ip, seqn.to_I,csum_to_i,len)
      else
        sprintf("%-4.0d  0x%2.2x  %-8s  %-15.15s %-15.15s 0x%8.8x  0x%4.4x   %-7d", 
        ls_age.to_i, options.to_i, ls_type.to_s_short, self.ls_id.to_ip, advertising_router.to_ip, seqn.to_I,csum_to_i,len)
      end
    end
    alias :to_s_dd :to_s
    
    # LS age: 44
    # Options: (No TOS-capability, No DC)
    # LS Type: Opaque Area Link
    # Link State ID: 1.0.0.0
    # Opaque Type: 1
    # Opaque ID: 0
    # Advertising Router: 0.0.0.3
    # LS Seq Number: 80000001
    # Checksum: 0xD12
    # Length: 116
    # Fragment number : 0
    def to_s_ios_verbose
      len = encode.size
      s = []
      s << ''
      s << ls_age.to_s_ios
      s << options.to_s_ios
      s << ls_type.to_s_ios
      if is_opaque?
        s << "Opaque Type: #{opaque_type.to_i}"
        s << "Opaque ID: #{opaque_id.to_i}"
      else
        s << "#{ls_id.to_s_ios} #{summary? ? "(summary Network Number)" : ''}"
      end
      s << advertising_router.to_s_ios
      s << sequence_number.to_s_ios
      s << "Checksum: #{format "0x%4X", csum_to_i}" if @_csum
      s << "Length: #{len}"
      s.join("\n  ")
    end
    
    def to_s_verbose
      len = encode.size
      s=[]
      s << self.class.to_s.split('::').last + ":"
      s << ls_age.to_s
      s << options.to_s
      s << ls_type.to_s
      s << advertising_router.to_s
      if is_opaque?
        # s << ls_id.to_s
      else
        s << ls_id.to_s
      end
      s << "SequenceNumber: " + sequence_number.to_s
      s << "LS checksum: #{format "%4x", csum_to_i}" if @_csum
      s << "length: #{@_size.unpack('n')}" if @_size
      s.join("\n   ")
    end
    
    alias :to_s_header :to_s
    
    def to_s_junos
      len = encode.size
      if is_opaque?
      else
        sprintf("%-7s %-1.1s%-15.15s  %-15.15s  0x%8.8x  %4.0d  0x%2.2x 0x%4.4x %3d", ls_type.to_junos, '', ls_id.to_ip, advertising_router.to_ip, seqn.to_I, ls_age.to_i, options.to_i, csum_to_i, len)
      end
    end

    def to_s_junos_verbose
      to_s_junos
    end
    
    def is_opaque?
      ls_type.is_opaque?
    end
    
    def encode_header
      header = []
      header << ls_age.encode
      header << [options.to_i].pack('C')
      header << ls_type.encode
      if is_opaque?
        header << @opaque_type.encode
        header << @opaque_id.encode
      else
        header << ls_id.encode
      end
      header << advertising_router.encode
      header << sequence_number.encode
      header << [''].pack('a4')
      header.join
    rescue => e
      p ls_age
      p ls_type
      p ls_id
      p advertising_router
      p sequence_number
      raise
    end
    alias :header_encode :encode_header
    
    def header_lsa
      self.class.new self
    end
    
    def encode(content='')
      lsa = []
      lsa << encode_header
      lsa << content
      lsa = lsa.join
      lsa[18..19]= @_size = [lsa.size].pack('n')
      lsa[16..17]= self.csum = cheksum(lsa[2..-1], 15).pack('CC')
      lsa
    end
    
    def encode_request
      req=[]
      req << ls_id.encode
      req << ls_type.encode
      req << @advertising_router.encode
      req.join
    end
    
    def parse(s)
      validate_checksum(s)
      ls_age, options, ls_type, ls_id, advr, seqn, csum, length, lsa = s.unpack('nCCNNNnna*')
      @ls_type = LsType.new ls_type
      @options = Options.new options
      @ls_age = LsAge.new ls_age
      @sequence_number = SequenceNumber.new seqn
      @advertising_router = AdvertisingRouter.new advr
      if is_opaque?
        @opaque_type = OpaqueType.new(ls_id>>24)
        @opaque_id = OpaqueId.new(ls_id & 0xffffff)
      else
        @ls_id = LsId.new ls_id
      end
      lsa
    end
    
    def key
      [ls_type.to_i, ls_id.to_i, advertising_router.to_i]
    end
    
    # -1  self older than other
    #  0  self equivalent to other
    # +1  self newer than other
    # TODO: compare advr router id.
    def <=>(other)
      raise RuntimeError unless self.key == other.key
      if self.sequence_number < other.sequence_number
        # puts "*** jme: our lsa older than other: our seq less than other seq ***"        
        -1
      elsif self.sequence_number > other.sequence_number
        # puts "*** jme: our lsa newer than other: our seq greater than other seq ***"        
        +1
      else
        if self.csum_to_i < other.csum_to_i
          # puts "*** jme: our lsa older than other: our csum less than other csum ***"        
          -1
        elsif self.csum_to_i > other.csum_to_i
          # puts "*** jme: our lsa newer than other: our csum greater than other csum ***"        
          +1
        else
          if (self.ls_age != other.ls_age and other.ls_age >= MaxAge) or
            ((other.ls_age - self.ls_age) > OSPFv2::MaxAgeDiff)
            # puts "*** jme: our lsa newer than other: age diff < maxage diff: #{(other.ls_age - self.ls_age)} ***"
            +1
          else
            # puts "*** jme: same lsa: age diff < maxage diff: #{(other.ls_age - self.ls_age)} ***"
            0
          end
        end
      end
    end
    
    def refresh(advertised_routers, refresh_time, seqn=nil)
      return unless advertised_routers.has?(advertising_router)
      return unless refresh?(refresh_time)
      @sequence_number = SequenceNumber.new(seqn) if seqn
      @sequence_number.incr
      @ls_age = LsAge.new
      retransmit
      self
    end
    
    def force_refresh(seqn)
      @sequence_number = SequenceNumber.new(seqn) if seqn
      @sequence_number.incr
      @ls_age = LsAge.new
      retransmit
      self
    end
    
    def refresh2(advertised_routers, age)
      return unless advertised_routers.has?(advertising_router)
      @sequence_number.incr
      @ls_age = LsAge.new(age)
      retransmit
      self
    end
    
    def maxage
      ls_age.maxage and retransmit
      self
    end
    
    def maxaged?
      @ls_age.maxaged?
    end
    
    def to_hash
      h = super
      h.delete(:time)
      h
    end
    
    def method_missing(method, *args, &block)
      if method.to_s =~ /^to_s_(ios|junos)_verbose/
        p " #{self.class}: #{method} IS MISSING!!! defaulting to :to_s_verbose"
        __send__ :to_s_verbose, *args, &block
      elsif method.to_s =~ /^to_s_(ios|junos)$/
        p $1
        __send__ :to_s, *args, &block
      else
        raise "missing: #{method} #{caller[0..2]}"
      end
    end

    protected
    
    def csum_to_i
      @_csum.unpack('n')[0]
    rescue Exception => e
      encode
      retry
    end
    

    private
    
    def csum=(value)
      raise if value.is_a?(Fixnum)
      @_csum=value
    end
    
    def refresh?(refresh_time)
      ls_age.to_i > refresh_time
    end
    
    def seqn
      @sequence_number
    end
    
    def validate_checksum(s)
      if ! cheksum(s[2..-1], 0) == [0,0]
        puts "*** checksum error ? #{cheksum(s[2..-1], 0)}"
      end
    end

    def cheksum(mess, k=0)
      len = mess.size
      
      if (k>0) 
        mess[k-1] = [0].pack('C')
        mess[k] = [0].pack('C')
      end
      
      c0,c1,n=0,0,0
      
      s = mess.dup
      while s.size>0 and n <= 4102 # MODX
        n +=1
        c0 += s.slice!(0,1).unpack('C')[0]
        c1 +=c0
      end
      
      c0 = c0%255
      c1 = c1%255
      
      ip = (c1<<8) + c0
      
      if k>0
        iq = ((len-k)*c0 - c1)%255 ; iq += 255 if (iq <= 0) 
        ir = (510 - c0 - iq) ; ir += -255 if (ir>255)
        return [iq,ir]
      else
        [c0,c1]
      end
      
    end
    
  end

end

load "../../../test/ospfv2/lsa/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
