
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
    
    AdvertisingRouter = Class.new(Id)
    LsId = Class.new(Id)
    LsAge = Class.new(LsAge)

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
    
    attr_reader :ls_age, :options, :ls_type
    attr_reader :ls_id
    attr_reader :advertising_router
    attr_reader :sequence_number
    
    attr_writer_delegate :advertising_router, :ls_id, :ls_age
    
    def initialize(arg={})
      arg = arg.dup
      @ls_age = LsAge.new
      @sequence_number = SequenceNumber.new
      @options = Options.new
      @ls_type = LsType.new klass_to_ls_type
      @ls_id = LsId.new
      @advertising_router = AdvertisingRouter.new
      @_length = 0
      @_rxmt_ = true
      
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
    
    def sequence_number=(seqn)
      @sequence_number = SequenceNumber.new(seqn)
    end
    
    def to_s
      len = encode.size
      s=[]
      s << self.class.to_s.split('::').last + ":"
      s << ls_age.to_s
      s << options.to_s
      s << ls_type.to_s
      s << advertising_router.to_s
      s << ls_id.to_s
      s << "SequenceNumber: " + sequence_number.to_s
      s << "LS checksum: #{format "%4x", csum_to_i}" if @_csum
      s << "length: #{@_size.unpack('n')}" if @_size
      s.join("\n   ")
    end
    
    alias :header_to_s :to_s
    
    def to_s_junos
      len = encode.size
      sprintf("%-7s %-1.1s%-15.15s  %-15.15s  0x%8.8x  %4.0d  0x%2.2x 0x%4.4x %3d", LsType.to_junos(ls_type.to_i), '', ls_id.to_ip, advertising_router.to_ip, seqn.to_I, ls_age.to_i, options.to_i, csum_to_i, len)
      
    end
    
    
    def encode_header
      header = []
      header << ls_age.encode
      header << [options.to_i].pack('C')
      header << ls_type.encode
      header << ls_id.encode
      header << advertising_router.encode
      header << sequence_number.encode
      header << [''].pack('a4')
      header.join
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
      @ls_id = LsId.new ls_id
      lsa
    end
    
    def key
      [ls_type.to_i, ls_id.to_i, advertising_router.to_i]
    end
    
    # -1  self older than other
    #  0  self equivalent to other
    # +1  self newer than other
    # FIXME: rename to 'newer'
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
      @sequence_number + 1
      @ls_age = LsAge.new
      retransmit
      self
    end
    
    def force_refresh(seqn)
      @sequence_number = SequenceNumber.new(seqn) if seqn
      @sequence_number + 1
      @ls_age = LsAge.new
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
    
    protected
    
    def csum_to_i
      @_csum.unpack('n')[0]
    rescue Exception => e
      encode
      retry
    end
    
    private
    
    def csum=(value)
      p caller if value.is_a?(Fixnum)
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
    
    def klass_to_ls_type
      case self.class.to_s
      when /Router/   ; 1
      when /Network/  ; 2
      when /Summary/  ; 3
      else
        1
      end
    end
    
    MODX=4102
     
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
      
      ip = (c1 <<8) + c0
      
      if k>0
        iq = ((len-k)*c0 - c1)%255 ; iq += 255 if (iq <= 0) 
        ir = (510 - c0 - iq) ; ir += -255 if (ir>255)
        return [iq,ir]
      else
        [c0,c1]
      end
      
    end
    
  end
  # 
  # lsa1 = Lsa.new :advertising_router=> '1.1.1.1',
  #                :ls_type => :router_lsa,
  #                :ls_id => '2.2.2.2',
  #                :options => 7,
  #                :ls_age => 0xffff
  # lsa2 = Lsa.new :advertising_router=> '1.1.1.1',
  #                :ls_type => :router_lsa,
  #                :ls_id => '2.2.2.2',
  #                :options => 7,
  #                :ls_age => 0xffff
  #                
  # # assert lsa1 == lsa2
  # lsa1.ls_age=2
  # # assert (lsa1 > lsa2)
  # lsa2.ls_age=1000
  # p (lsa1 > lsa2)
  # # assert (lsa1 < lsa2)
  
end

load "../../test/ospfv2/lsa/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__


module Ospf
class LSA
  attr :do_not_refresh, true
  attr :dd_seqn, true
  attr :described, true
  
  def ack
    self.header.rxmt=false
  end
  def retransmit
    self.header.rxmt=true
  end
  def ack?
    self.header.rxmt == false
  end
  def is_acked?
    self.ack?
  end
end
end

  def to_s
    "age: #{lsage}, options: #{@options.to_s}, type: #{@lstype}, lsid: #{lsid}, advr: #{advr}, " +
    "seqn: #{seqn_to_s}, csum: #{@csum}, length: #{@length}"
  end
  
  def to_s
    sprintf("%s age %d opt 0x%x lsid %s advr %s len %d seqn 0x%x csum 0x%x", LSA_Header.lstype_to_s[@lstype], lsage, @options.to_i, lsid, advr, @length, seqn.to_i, @csum)
  end
  
  def LSA_Header.headline
    s = "Age  Options  Type    Link-State ID   Advr Router     Sequence   Checksum  Length"
  end

  def to_s_junos_style(lstype='',rtype=' ')
    sprintf("%-7s %-1.1s%-15.15s  %-15.15s  0x%8.8x  %4.0d  0x%2.2x 0x%4.4x %3d", lstype, rtype, lsid, advr, seqn.to_i, lsage, @options.to_i, @csum, @length)
  end
  
  def to_s2
    sprintf("%-4.0d  0x%2.2x  %-8s  %-15.15s %-15.15s 0x%8.8x  0x%4.4x   %-7d", lsage, @options.to_i, LSA_Header.lstype_to_s[@lstype], lsid, advr, seqn.to_i, @csum, @length)
  end


module LSA
  include Ospf
    
  def eql?(lsa)
    self.header.eql?(lsa)
  end
  
  def lstype
    self.header.lstype
  end
  def lsid
    self.header.lsid
  end
  def lsage
    self.header.lsage
  end
  def lsage=(age)
    self.header.lsage=age
  end
  def advr
    self.header.advr
  end
  def seqn
    SequenceNumber.new(self.header.seqn)
  end
  
  def key
    [self.lstype,self.lsid,self.advr]
  end

  def packet_size(packet, header)
    header.length=packet.size
    packet[18..19]=[header.length].pack('n')
  end
  
  def packet_fletchsum(packet)
    csum = self.fletcher_csum_lsa(packet)
    @header.csum = csum
    packet[16..17] = csum
    packet
  end
  
  def LSA.validate_checksum(packet)
    #TODO validate_checksum
  end

  def incr_seqn(n=1)
    self.header.incr_seqn(n)
  end

 
  def refresh(refresh_time, _seqn=nil)
    def refresh?(ls)
      ls.lsage.to_i > @ls_refresh_time # and @advrs.key?(ls.advr)
    end
    
    self.header.seqn = _seqn unless _seqn.nil?
    self.incr_seqn
    self.lsage=0
    self.header.time=Time.now
    self
  end
  
  def maxage
    self.header.lsage=MaxAge
    self
  end
  
  def maxaged?
    self.lsage == MaxAge
  end
  
  def clone
    clone=super()
    #clone.header = self.header.clone
  end
  
end


__END__
