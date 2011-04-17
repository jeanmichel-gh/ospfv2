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


require 'lsa/lsa'

require 'ie/metric'
require 'ie/mt_metric'
require 'ie/id'
require 'ie/external_route'

module OSPFv2
  
  class External_Base < Lsa
    
    unless const_defined?(:Netmask)
      Netmask = Class.new(OSPFv2::Id)
      ExternalRoute = Class.new(OSPFv2::ExternalRoute)
    end
    
    attr_reader :netmask, :external_route, :mt_metrics
    attr_writer_delegate :netmask, :external_route
    
    def initialize(ls_type, arg={})
      @netmask, @external_route = nil
      @mt_metrics=[]
      @ls_type = LsType.new(ls_type)
      super arg
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
      super
    end
    
    # Network Mask: /24
    #       Metric Type: 1 (Comparable directly to link state metric)
    #       TOS: 0 
    #       Metric: 0 
    #       Forward Address: 0.0.0.0
    #       External Route Tag: 0
    #       Metric Type: 1 (Comparable directly to link state metric)
    #       TOS: 10 
    #       Metric: 20 
    #       Forward Address: 0.0.0.0
    #       External Route Tag: 10

    def to_s_ios
      super + external_route.tag.to_s
    end

    def to_s_ios_verbose
      s = []
      mt_metrics = self.mt_metrics.collect
      s << super
      s << "Network Mask: #{netmask}"
      ext = []
      ext << "    #{external_route}"
      ext << mt_metrics.collect { |x| x.to_s }
      s << ext.join("\n      ")
      s.join("\n  ")
    end
    

    def to_s_verbose
      mt_metrics = self.mt_metrics.collect
      super  +
      ['',netmask, external_route, *mt_metrics ].collect { |x| x.to_s }.join("\n   ")
    end
   
    def to_s_junos
      super
    end
    
    # Extern   50.0.2.0         128.3.0.1        0x80000001    39  0x0  0x1454  48
    #   mask 255.255.255.0
    #   Topology default (ID 0)
    #     Type: 1, Metric: 0, Fwd addr: 0.0.0.0, Tag: 0.0.0.0
    #   Topology default (ID 0)
    #     Type: 1, Metric: 30, Fwd addr: 0.0.0.0, Tag: 0.0.0.10
    def to_s_junos_verbose
      mt_metrics = self.mt_metrics.collect
      super  +
      ['',netmask, external_route, *mt_metrics ].collect { |x| x.to_s }.join("\n   ")
    end
    
    def mt_metrics=(val)
      # p "in mt_metrics=(val)"
      # p val
      [val].flatten.each { |x| self << x }
    end
    
    def <<(ext_route)
      @mt_metrics ||=[]
      # p "calling MtExternalRoute with #{ext_route.inspect}"
      route = MtExternalRoute.new(ext_route)
      # p route
      @mt_metrics << route
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

    unless const_defined?(:ExternalRoute)
      ExternalRoute = Class.new(OSPFv2::ExternalRoute)
    end

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
      arg = fix_hash(arg) if arg.is_a?(Hash)
      super 5, arg
    end

     private

     def fix_hash(arg)
       # p 'HERE'
       # p arg
       if arg[:network]
         addr = IPAddr.new arg[:network]
         arg.delete :network
         arg.store :netmask, addr.netmask
         arg.store :ls_id, addr.to_s
       end
       route = arg[:external_route] ||={}
       [:metric, :forwarding_address, :type, :tag].each do |e|
         next unless arg[e]
         route.store(e, arg[e]) if arg[e]
         arg.delete(e)
       end
       arg.merge!(:external_route=>route)
       # p "FIXED arg: #{arg.inspect}"
       arg
     end
 
  end
  
  def AsExternal.new_hash(h)
    new(h)
  end

end

load "../../../test/ospfv2/lsa/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
