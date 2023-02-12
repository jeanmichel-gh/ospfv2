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

require 'lsa/lsa'

require 'ie/metric'
require 'ie/mt_metric'
require 'ie/id'

module OSPFv2

  unless const_defined?(:Netmask)
    Netmask = Class.new(Id)
  end
  
  class Summary_Base < Lsa
    include CommonMetric
    
    attr_reader :metric, :netmask, :mt_metrics
    
    def initialize(type, arg={})
      @netmask=Netmask.new(0)
      @metric=nil
      @mt_metrics=[]
      @ls_type = LsType.new(type)
      super arg
    end
    
    def encode
      @netmask ||= Netmask.new
      @metric  ||= Metric.new
      summary =[]
      summary << netmask.encode
      summary << metric.encode
      summary << mt_metrics.collect { |x| x.encode } if mt_metrics
      super summary.join
    end
    
    def parse(s)
      netmask, metric, mt_metrics = super(s).unpack('NNa*')
      @netmask = Netmask.new netmask
      @metric = Metric.new metric
      while mt_metrics.size>0
        self << MtMetric.new(mt_metrics.slice!(0,4))
      end
    end
    
    def to_hash
      super
    end
    
    def to_s_verbose
      super  +
      ['',netmask, metric, *mt_metrics].collect { |x| x.to_s }.join("\n   ")
    end
    
    def to_s_ios_verbose
      s = []
      s << super
      s << "Network Mask: " + netmask.to_s(false)
      s << "      TOS 0 Metrics: #{metric.to_i}"
      s << @mt_metrics.collect { |mt| "\n      #{mt.to_s}" }.join unless @mt_metrics.empty?
      s.join("\n  ")
    end
    
    def to_s_junos_verbose
      mask = "mask #{netmask.to_ip}"
      super +
      ['', mask, metric.to_s_junos, *mt_metrics.collect{|m| m.to_s_junos}].join("\n  ")
    rescue
      p netmask
      p self
    end
    
    def to_s_junos
      super
    end
    
  end
  
  class Summary < Summary_Base
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
      
      def base_ip_addr(addr=SUMMARY_BASE_ADDRESS)
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
      case arg
      when Hash
        arg = fix_hash(arg).merge!({:ls_type => :summary,})
      end
      super 3, arg
    end
    
    private
    
    def fix_hash(arg)
      
      if arg[:network]
        addr = IPAddr.new arg[:network]
        arg.delete :network
        arg.store :netmask, addr.netmask
        arg.store :ls_id, addr.to_s
      end
      arg
    rescue => e
      p 'HERE'
      p arg
      raise
    end
    
  end
  
  class AsbrSummary < Summary_Base
    def initialize(arg={})
      super 4, arg
    end
  end
  
  class Summary_Base
    def self.new_hash(hash)
      raise ArgumentError, "Invalid argument" unless hash.is_a?(Hash)
      new(hash)
    end
  end

end

load File.absolute_path("test/unit/lsa/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}") if __FILE__ == $0


__END__


=begin rdoc


A.4.4 Summary-LSAs

    Summary-LSAs are the Type 3 and 4 LSAs.  These LSAs are originated
    by area border routers. Summary-LSAs describe inter-area
    destinations.  For details concerning the construction of summary-
    LSAs, see Section 12.4.3.

    Type 3 summary-LSAs are used when the destination is an IP network.
    In this case the LSA's Link State ID field is an IP network number
    (if necessary, the Link State ID can also have one or more of the
    network's "host" bits set; see Appendix E for details). When the
    destination is an AS boundary router, a Type 4 summary-LSA is used,
    and the Link State ID field is the AS boundary router's OSPF Router
    ID.  (To see why it is necessary to advertise the location of each
    ASBR, consult Section 16.4.)  Other than the difference in the Link
    State ID field, the format of Type 3 and 4 summary-LSAs is
    identical.


        0                   1                   2                   3
        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |            LS age             |     Options   |    3 or 4     |
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
       |      0        |                  metric                       |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |     TOS       |                TOS  metric                    |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                              ...                              |


    For stub areas, Type 3 summary-LSAs can also be used to describe a
    (per-area) default route.  Default summary routes are used in stub
    areas instead of flooding a complete set of external routes.  When
    describing a default summary route, the summary-LSA's Link State ID
    is always set to DefaultDestination (0.0.0.0) and the Network Mask
    is set to 0.0.0.0.

    Network Mask
        For Type 3 summary-LSAs, this indicates the destination
        network's IP address mask.  For example, when advertising the
        location of a class A network the value 0xff000000 would be
        used.  This field is not meaningful and must be zero for Type 4
        summary-LSAs.

    metric
        The cost of this route.  Expressed in the same units as the
        interface costs in the router-LSAs.

    Additional TOS-specific information may also be included, for
    backward compatibility with previous versions of the OSPF
    specification ([Ref9]). For each desired TOS, TOS-specific
    information is encoded as follows:

    TOS IP Type of Service that this metric refers to.  The encoding of
        TOS in OSPF LSAs is described in Section 12.3.

    TOS metric
        TOS-specific metric information.


=end
