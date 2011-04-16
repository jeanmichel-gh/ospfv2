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

require 'infra/ospf_common'
require 'ie/id'
require 'ie/metric'
require 'ie/mt_metric'
require 'ie/router_link_type'

module OSPFv2
  
  class RouterLink
    include Common
    include CommonMetric
    
    unless const_defined?(:LinkId)
      LinkId = Class.new(Id)
      LinkData = Class.new(Id)
    end

    attr_reader :link_id, :link_data, :router_link_type, :metric, :mt_metrics
    
    attr_writer_delegate :link_id, :link_data, :router_link_type
    
    def initialize(arg={})
      arg = arg.dup
      if arg.is_a?(Hash)
        @link_id, @link_data, @router_link_type, @metric = nil, nil, nil, nil
        @mt_metrics = []
        set arg
      elsif arg.is_a?(String)
        parse arg
      elsif arg.is_a?(self.class)
        parse arg.encode
      else
        raise ArgumentError, "Invalid Argument: #{arg.inspect}"
      end
    end
    
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |                          Link ID                              |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |                         Link Data                             |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |     Type      |     # TOS     |            metric             |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |                              ...                              |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |      TOS      |        0      |          TOS  metric          |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    def encode
      @link_id    ||= LinkId.new
      @link_data  ||= LinkData.new
      @router_link_type  ||= RouterLinkType.new
      @metric   ||= Metric.new
      rlink =[]
      rlink << link_id.encode
      rlink << link_data.encode
      rlink << router_link_type.encode
      rlink << [mt_metrics.size].pack('C')
      rlink << metric.encode('n')
      rlink << mt_metrics.collect { |x| x.encode }
      rlink.join
    end
    
    def to_s(ident=4)
      encode unless @router_link_type
      self.class.to_s.split('::').last + ":" +
      ['',link_id, link_data, router_link_type, metric, *mt_metrics].compact.collect { |x| x.to_s }.join("\n"+" "*ident)
    end
    
    def to_s_junos
      s = "  id #{link_id.to_ip}, data #{link_data.to_ip}, Type #{RouterLinkType.to_junos(router_link_type.to_i)} (#{router_link_type.to_i})"
      s +="\n    Topology count: #{@mt_metrics.size}, Default metric: #{metric.to_i}"
      s += @mt_metrics.collect { |mt| "\n    #{mt.to_s}" }.join

    end
    
    class << self
      class_eval {
        RouterLinkType.each { |x| 
          define_method "new_#{x}" do |*args|
            OSPFv2::RouterLink.const_get(x.to_klass).send :new, *args
          end
        }
      }
    end
    
    RouterLinkType.each { |x| 
      klassname = Class.new(self) do
        define_method(:initialize) do |arg|
          arg ||={}
          arg[:router_link_type] = x if arg.is_a?(Hash)
          super arg
        end
        define_method(:to_hash) do
          super().merge :router_link_type => x
        end
      end
      self.const_set(x.to_klass, klassname)
    }
    
    def parse(s)
      @mt_metrics ||=[]
      link_id, link_data, router_link_type, ntos, metric, mt_metrics = s.unpack('NNCCna*')
      @link_id = LinkId.new link_id
      @link_data = LinkData.new link_data
      @router_link_type = RouterLinkType.new router_link_type
      @metric = Metric.new metric
      while mt_metrics.size>0
        self << MtMetric.new(mt_metrics.slice!(0,4))
      end
    end
    
  end
  
end


load "../../../test/ospfv2/ie/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
