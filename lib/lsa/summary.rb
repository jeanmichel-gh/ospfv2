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

  Netmask = Class.new(Id)
  
  class Summary_Base < Lsa
    
    attr_reader :metric, :netmask, :mt_metrics
    
    def initialize(arg={})
      @netmask=nil
      @metric=nil
      @mt_metrics=[]
      super
    end
    
    def mt_metrics=(val)
      [val].flatten.each { |x| self << x }
    end
    
    def <<(metric)
      @mt_metrics ||=[]
      @mt_metrics << MtMetric.new(metric)
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
    
    def to_s_default(*args)
      super  +
      ['',netmask, metric, *mt_metrics].collect { |x| x.to_s }.join("\n   ")
    end
    
    def to_s_junos_verbose
      mask = "mask #{netmask.to_ip}"
      super +
      ['', mask, metric.to_s_junos, *mt_metrics.collect{|m| m.to_s_junos}].join("\n  ")
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
      if arg.is_a?(Hash)
        arg = fix_hash(arg).merge!({:ls_type => :summary_lsa,}) 
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
      arg
    end
    
  end
  
  class AsbrSummary < Summary_Base
    def initialize(arg={})
      arg.merge!({:ls_type => :asbr_summary_lsa,}) if arg.is_a?(Hash)
      super
    end
  end
  
  class Summary_Base
    def self.new_hash(hash)
      raise ArgumentError, "Invalid argument" unless hash.is_a?(Hash)
      new(hash)
    end
  end

end


load "../../../test/ospfv2/lsa/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__

# if arg.is_a?(Hash)
#   arg.merge!({:ls_type=> :summary_lsa}) unless arg.has_key?(:ls_type) 
#   set arg
#    super
# elsif arg.is_a?(String)
#   parse arg
# elsif arg.is_a?(self.class)
#   parse arg.encode
# else
#   raise ArgumentError, "Invalid argument", caller
# end

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


module Ospf
  module Summary_Shared
    private
    def __to_s_junos_style__(sum_type, rtype=' ')
      enc
      s = @header.to_s_junos_style(sum_type,rtype)
      s +="\n  mask #{netmask}"
      s +="\n  Topology default (ID #{@mt_id[0].id}) -> Metric: #{@mt_id[0].metric}"
      s += @mt_id[1..-1].collect { |mt| "\n  #{mt.to_s_junos_style}" }.join
      s
    end
    def __to_hash__(sum_type)
      enc
      h = @header.to_hash.merge({:lsa_type=>sum_type, :netmask => netmask,})
      if @mt_id.size > 1 or @mt_id[0].id != 0
        h[:mt_id] = @mt_id.collect { |mt_id| mt_id.to_hash } unless @mt_id.nil?
      else
        h[:metric] = @mt_id[0].metric
      end
      h
    end
    private :__to_s_junos_style__, :__to_hash__
    
  end
end

require 'lsa_header'
  
module Ospf

  class SummaryLSAs < LSA
    include Ospf
    include Ospf::Ip
    include Ospf::Summary_Shared

    attr :header
    attr_accessor :mt_id

    def initialize(arg={})
      @netmask, @mt_id = 0, []
      if arg.is_a?(Hash) then
        arg[:lstype]=3 if arg[:lstype].nil?
        @header = LSA_Header.new(arg)
        set(arg)
      elsif arg.is_a?(String)
        __parse(arg)
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def set(arg)
      return self unless arg.is_a?(Hash)
      @header.set(arg)
      unless arg[:netmask].nil?
        _netmask = arg[:netmask]
        @netmask =  _netmask.is_a?(String) ? ip2long(_netmask) : _netmask
      end      

      unless arg[:metric].nil?
        metric=arg[:metric]
        @mt_id << MT.new({:metric=>metric})
      end
      unless arg[:mt_id].nil?
        arg[:mt_id].each { |mt_id| 
          mt_id.is_a?(MT) ? @mt_id << mt_id : @mt_id << MT.new(mt_id) 
        }
      end
      self
    end
    
    def <<(arg)
      append_metric(arg)
    end
    
    def enc
      packet = @header.enc
      packet+= __enc([[@netmask,'N'],])
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
        @mt_id << MT.new(mt_ids.slice!(0,4))
      end            
    end
    private :__parse

    def to_s
      enc
      s = @header.to_s
      s += "\n      netmask #{netmask}" 
      s += "\n      " if @mt_id.size>0
      s += @mt_id.collect { |mt| mt.to_s }.join("\n      ")
    end
    
    def metric
      @mt_id[0].metric
    end

  end

  class SummaryLSA < SummaryLSAs
    def initialize(arg={})
      arg.merge!({:lstype => 3,}) if arg.is_a?(Hash)
      super
    end
    def to_s_junos_style(rtype=' ')
      __to_s_junos_style__('Summary', rtype)
    end    
    def to_hash
      __to_hash__('Summary')
    end
  end

  class ASBR_SummaryLSA < SummaryLSAs
    def initialize(arg={})
      arg.merge!({:lstype => 4, :metric=>0}) if arg.is_a?(Hash)
      super(arg)
    end
     def to_s_junos_style(rtype=' ')
       __to_s_junos_style__('ASBRSum', rtype)
    end
    def to_hash
      __to_hash__('ASBRSum')
    end
  end
end

if __FILE__ == $0
  load '../test/lsa_summary_test.rb'
end


