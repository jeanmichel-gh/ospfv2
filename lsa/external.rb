
require 'lsa/lsa'

require 'ie/metric'
require 'ie/mt_metric'
require 'ie/id'
require 'ie/external_route'

module OSPFv2
  
  class External_Base < Lsa
    
    Netmask = Class.new(OSPFv2::Id)
    
    
    attr_reader :netmask, :external_route, :mt_metrics
    attr_writer_delegate :netmask
    
    def initialize(arg={})
      @netmask, @external_route = nil
      @mt_metrics=[]
      super
    end
    
    def encode
      @netmask ||= Netmask.new
      external =[]
      external << netmask.encode
      external << external_route.encode
      external << mt_metrics.collect { |x| x.encode } if mt_metrics
      super external.join
    end
    
    def parse(s)
      s = super(s)
      netmask, external_route = s.slice!(0,16).unpack('Na*')
      @netmask = Netmask.new netmask
      @external_route = ExternalRoute.new external_route
      while s.size>0
        self << MtExternalRoute.new(s.slice!(0,12))
      end
    end
    
    def to_hash
      super
    end
    
    def to_s
      mt_metrics = self.mt_metrics.collect
      super  +
      ['',netmask, external_route, *mt_metrics ].collect { |x| x.to_s }.join("\n   ")
    end
    
    def mt_metrics=(val)
      [val].flatten.each { |x| self << x }
    end
    
    def <<(ext_route)
      @mt_metrics ||=[]
      @mt_metrics << MtExternalRoute.new(ext_route)
      self
    end
    
    def forwarding_address=(val)
      @external_route.forwarding_address=(val)
    end
    
    def type=(val)
      @external_route.type=(val)
    end
    
    def tag=(val)
      @external_route.tag=(val)
    end
    
    def metric=(val)
      @external_route.metric=(val)
    end
    
    # FIXME: should be a mixin and extended  Summary and External?
    class << self
      def count
        @count ||= 0
      end
      
      def incr_count
        self.count
        @count += 1
      end
      
      def reset
        @count = nil
      end
      
      def base_ip_addr(addr=EXTERNAL_BASE_ADDRESS)
        @base_addr ||= IPAddr.new(addr)
      end
      
      def network
        @base_addr + count
      end
      
      def new_lsdb(arg={})
        new({:network=> base_ip_addr ^ incr_count}.merge(arg))
      end
      
    end

  end

  class AsExternal < External_Base

    ExternalRoute = Class.new(OSPFv2::ExternalRoute)

    class << self
      def count
        @count ||= 0
      end

      def incr_count
        self.count
        @count += 1
      end

      def reset
        @count = nil
      end

      def base_ip_addr(addr=EXTERNAL_BASE_ADDRESS)
        @base_addr ||= IPAddr.new(addr)
      end

      def network
        @base_addr + count
      end

      def new_lsdb(arg={})
        new({:network=> base_ip_addr ^ incr_count}.merge(arg))
      end

    end

    def initialize(arg={})
       if arg.is_a?(Hash)
         arg = fix_hash(arg).merge!({:ls_type => :as_external_lsa,}) 
       end
       super
     end

     private

     def fix_hash(arg)
       if arg[:network]
         addr = IPAddr.new arg[:network]
         arg.delete :network
         arg.store :netmask, addr.netmask
         arg.store :ls_id, addr.to_s
       end
       ext_route = arg[:external_route] ||={}
       ext_route.store :metric, arg[:metric]  if arg[:metric]
       ext_route.store :forwarding_address, arg[:forwarding_address]  if arg[:forwarding_address]
       ext_route.store :type, arg[:type]  if arg[:type]
       ext_route.store :tag, arg[:tag]  if arg[:tag]
       arg.delete(:metric)
       arg.delete(:forwarding_address)
       arg.delete(:type)
       arg.delete(:tag)
       arg.merge!(:external_route=>ext_route)
       arg
     end
 
  end
  
  def AsExternal.new_hash(h)
    new(h)
  end

end

load "../../test/ospfv2/lsa/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__

__END__

#
#  Created by Jean-Michel Esnault.
#  Copyright (c) 2008. All rights reserved.
#
=begin rdoc

A.4.5 AS-external-LSAs

    AS-external-LSAs are the Type 5 LSAs.  These LSAs are originated by
    AS boundary routers, and describe destinations external to the AS.
    For details concerning the construction of AS-external-LSAs, see
    Section 12.4.3.

    AS-external-LSAs usually describe a particular external destination.
    For these LSAs the Link State ID field specifies an IP network
    number (if necessary, the Link State ID can also have one or more of
    the network's "host" bits set; see Appendix E for details).  AS-
    external-LSAs are also used to describe a default route.  Default
    routes are used when no specific route exists to the destination.
    When describing a default route, the Link State ID is always set to
    DefaultDestination (0.0.0.0) and the Network Mask is set to 0.0.0.0.


        0                   1                   2                   3
        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |            LS age             |     Options   |      5        |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                        Link State ID                          |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                     Advertising Router                        |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                     LS sequence number                        |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |         LS checksum           |             length            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                         Network Mask                          |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |E|     0       |                  metric                       |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                      Forwarding address                       |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                      External Route Tag                       |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |E|    TOS      |                TOS  metric                    |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                      Forwarding address                       |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                      External Route Tag                       |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                              ...                              |



    Network Mask
        The IP address mask for the advertised destination.  For
        example, when advertising a class A network the mask 0xff000000
        would be used.

    bit E
        The type of external metric.  If bit E is set, the metric
        specified is a Type 2 external metric.  This means the metric is
        considered larger than any link state path.  If bit E is zero,
        the specified metric is a Type 1 external metric.  This means
        that it is expressed in the same units as the link state metric
        (i.e., the same units as interface cost).

    metric
        The cost of this route.  Interpretation depends on the external
        type indication (bit E above).

    Forwarding address
        Data traffic for the advertised destination will be forwarded to
        this address.  If the Forwarding address is set to 0.0.0.0, data
        traffic will be forwarded instead to the LSA's originator (i.e.,
        the responsible AS boundary router).

    External Route Tag
        A 32-bit field attached to each external route.  This is not
        used by the OSPF protocol itself.  It may be used to communicate
        information between AS boundary routers; the precise nature of
        such information is outside the scope of this specification.

    Additional TOS-specific information may also be included, for
    backward compatibility with previous versions of the OSPF
    specification ([Ref9]). For each desired TOS, TOS-specific
    information is encoded as follows:

    TOS The Type of Service that the following fields concern.  The
        encoding of TOS in OSPF LSAs is described in Section 12.3.

    bit E
        For backward-compatibility with [Ref9].

    TOS metric
        TOS-specific metric information.

    Forwarding address
        For backward-compatibility with [Ref9].

    External Route Tag
        For backward-compatibility with [Ref9].



(RFC 4915)

        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |                         Network Mask                          |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |E|     0       |                  metric                       |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |                      Forwarding address                       |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |                      External Route Tag                       |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |E|    MT-ID    |              MT-ID  metric                    |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |                      Forwarding address                       |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |                      External Route Tag                       |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |                              ...                              |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

=end

require 'lsa_header'
  
module Ospf
  class ExternalData
    include Ospf
    include Ospf::Ip
    
    attr_reader :metric, :tag, :header, :id
    
    def initialize(arg={})
      @metric, @metric_type, @fwd_address, @tag, @id = 0, 0, 0, 0, 0, 0      
      if arg.is_a?(Hash) then
        __set(arg)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end
    
    def fwd_address=(arg)
      @fwd_address=ip2long(arg[:fwd_address]) unless arg[:fwd_address].nil?
    end
    def fwd_address
      long2ip(@fwd_address) unless @fwd_address.is_a?(String)
    end
    def tag=(arg)
      @tag=ip2long(arg[:tag]) unless arg[:tag].nil?
    end
    def metric_type=(arg)
      unless arg[:metric_type].nil?
        @metric_type= arg[:metric_type] - 1
      end
    end
    def metric=arg      
      @metric=arg[:metric] unless arg[:metric].nil?
    end          
    def id=(arg)
      unless arg[:id].nil?
        @id=arg[:id]
      end
    end
    
    def __set(arg)
       return self unless arg.is_a?(Hash)
       self.fwd_address=arg
       self.metric_type=arg
       self.metric=arg
       self.tag=arg
       self.id=arg
     end
     private :__set

     def __parse(s)
       arr = s.unpack('NNN')
       _metric = arr[0]
       @metric = _metric & 0x00ffffff
       @metric_type = _metric >> 31
       @id = _metric >> 24 & 0x7f
       @fwd_address = arr[1]
       @tag = arr[2]
     end
     private :__parse
     
     def enc
       _metric= @metric | 0x80000000*(@metric_type%2) | @id << 24
       __enc([
         [_metric,  'N'], 
         [@fwd_address, 'N'], 
         [@tag,     'N'], 
         ])
     end

     def metric_type
       @metric_type + 1
     end

     def metric_type_to_s
       case @metric_type
       when 0 ; "e1"
       when 1 ; "e2"
       else ; "bogus"
       end
     end

     def to_s
       enc
       "(ID: #{@id}) -> metric: #{@metric}(#{metric_type_to_s}), fwd-addr: #{fwd_address}, tag: #{@tag}"      
     end

     def to_s_junos_style
       enc
        s="  Topology default (ID 0)"
        s +="\n    Type: #{metric_type}, Metric: #{@metric}, Fwd addr: #{fwd_address}, Tag: #{long2ip(@tag)}"
        s 
     end

    def to_hash
      {
        :fwd_address => fwd_address, 
        :id => @id, 
        :metric => @metric, 
        :metric_type => metric_type,
        :tag => @tag,
      }
    end    
    
  end


  class ExternalLSA < LSA
    include Ospf
    include Ospf::Ip

    attr_reader :header, :mt_id
    attr_writer :header, :mt_id

    def initialize(arg={})
      @netmask, @mt_id= 0,[]
      if arg.is_a?(Hash) then
        arg[:lstype]=5 if arg[:lstype].nil?
        @header = LSA_Header.new(arg)
        if arg[:metric].nil? and arg[:mt_id].nil?
          arg.merge!({:metric=>0})
        end
        __set(arg)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def netmask=(arg)
      @netmask=ip2long(arg[:netmask]) unless arg[:netmask].nil?
    end

    def __set(arg)
      return self unless arg.is_a?(Hash)
      @header.set(arg)
      self.netmask=arg

      unless arg[:metric].nil?
        metric=arg[:metric]
        @mt_id << ExternalData.new(arg)
      end

      unless arg[:mt_id].nil?
        arg[:mt_id].each { |mt_id| 
          mt_id.is_a?(ExternalData) ? @mt_id << mt_id : @mt_id << ExternalData.new(mt_id) 
        }
      end
      self
    end
    private :__set
        
    def <<(arg)
      append_metric(arg)
    end
    
    def append_metric(arg)
      return self unless arg.is_a?(Hash)
      @mt_id << ExternalData.new(arg) 
    end

    def enc
      packet  = @header.enc(5)
      packet += __enc([[@netmask,'N'],])
      packet +=@mt_id.collect {|mt_id| mt_id.enc}.join
      packet_size(packet,@header)
      packet_fletchsum(packet)
    end

    def __parse(s)
      @header = LSA_Header.new(s)
      arr = s[20..24].unpack("N")
      @netmask = arr[0]
      mt_ids = s[24..-1]
      while mt_ids.size>0
        @mt_id << ExternalData.new(mt_ids.slice!(0,12))
      end            
    end
    private :__parse

    def to_s
      enc
      s = @header.to_s + "\n      netmask #{netmask}" +
      @mt_id.collect { |mt| "\n      #{mt.to_s}" }.join
    end
    
    def to_s_junos_style(rtype=' ')
      enc
      s = @header.to_s_junos_style('Extern',rtype)
      s +="\n  mask #{netmask}"
      s +="\n" + @mt_id.collect { |mt| mt.to_s_junos_style }.join("\n")
      s
    end

    def to_hash
      enc
      h = @header.to_hash.merge({:lsa_type=> 'External', :netmask => netmask,})
      if @mt_id.size > 1 or @mt_id[0].id != 0
        h[:mt_id] = @mt_id.collect { |mt_id| mt_id.to_hash } unless @mt_id.nil?
      else
        h[:metric] = @mt_id[0].metric
        h[:fwd_address] = @mt_id[0].fwd_address
        h[:metric_type] = @mt_id[0].metric_type
        h[:tag] = @mt_id[0].tag
      end
      h
    end
    
    def metric
      @mt_id[0].metric
    end

    def metric_type
      @mt_id[0].metric_type
    end

  end
    
  class ExternalType5_LSA < ExternalLSA
    def initialize(arg={})
      arg.merge!({:lstype => 5}) if arg.is_a?(Hash)
      super(arg)
    end
  end

  class ExternalType7_LSA < ExternalLSA
    def initialize(arg={}) 
      arg.merge!({:lstype => 7}) if arg.is_a?(Hash)
      super(arg)
    end
  end

end

require 'pp'

if __FILE__ == $0     
   load '../test/lsa_external_test.rb'
end
