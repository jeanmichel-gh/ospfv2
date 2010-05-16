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
require 'ls_db/common'

module OSPFv2::LSDB

  class Link

    class << self
        
      def <<(val)
        @_links ||={}
        @_links.store(val.id, val)
      end

      def all
        @_links ||={}
        @_links
      end

      def ids
        @_links ||={}
        @_links.keys
      end

      def count
        @count ||= 0
      end

      def incr_count
        self.count
        @count += 1
      end

      def reset
        @_links={}
        @count = nil
      end

      def base_ip_addr(addr=LINK_BASE_ADDRESS)
        @base_addr ||= IPAddr.new(addr)
      end

      def find_by_id(router_id)
        all.find_all { |k,v| v.router_id.to_ip == router_id }
      end

      def reset_ip_addr
        @base_addr=nil
      end
      
      def [](val)
        @_links[val]
      end

    end
    
    include OSPFv2::Common

    #FIXME: all IE should be in an IE namespace
    RouterId = Class.new(OSPFv2::Id)
    NeighborId = Class.new(OSPFv2::Id)

    attr_reader :router_id, :neighbor_id, :metric

    #TODO: :metric => [10,20] ... revisit
    #      :metric_ifa => 10, :metric_ifb=>20
    def initialize(arg={})
      @_state = :down
      @_id = self.class.incr_count
      @prefix=nil
      @router_id= RouterId.new arg[:router_id] || '1.1.1.1'
      @neighbor_id= NeighborId.new arg[:neighbor_id] || '2.2.2.2'
      @metric = 0
      set arg
      @lsas=[]
      Link << self
      self
    end
    [:local, :remote].each_with_index { |n,i| 
      define_method("#{n}_prefix") do
        instance_variable_set("@_#{n}_prefix", _address_(i+1))
      end 
    }

    def id
      @_id
    end

    attr_reader :local_lsa, :remote_lsa

    def local_lsa=(lsa)
      @local_lsa=lsa
    end
    
    def remote_lsa=(lsa)
      @remote_lsa=lsa
    end    

    def network
      @network ||=IPAddr.new(Link.base_ip_addr.^(@_id-1))
    end

    def to_s
      rid = router_id.to_s.split(":")
      nid = neighbor_id.to_s.split(":")
      sprintf("%3d\# %s: %-15.15s  %s:%-15.15s Network %-15.15s %s",
      @_id, rid[0], rid[1], nid[0], nid[1], network_to_s, metric)
    end

    def network_to_s
      [network, network.mlen].join('/')
    end

    def method_missing(name, *args, &block)
      if name.to_s =~ /^(local|remote)_address/
        (__send__ "#{$1}_prefix").split('/')[0]
      else
        p name
        raise
      end
    end


    private


    def _address_(host=1)
      network + host
    end

  end
  
end

load "../../../test/ospfv2/ls_db/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
