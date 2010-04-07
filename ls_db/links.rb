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

      def reset_ip_addr
        @base_addr=nil
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
        raise
      end
    end


    private


    def _address_(host=1)
      network + host
    end

  end
  
end


if __FILE__ == $0
  require "test/unit"

  require "ls_db/links"

  class TestLsDbLinks < Test::Unit::TestCase
    include OSPFv2::LSDB
    def setup
      Link.reset
    end
    def test_link_count
      assert_equal 0, Link.count
      assert link = Link.new
      assert link = Link.new
      assert link = Link.new
      assert_equal 3, Link.count
      assert_equal 3, Link.all.size
      assert_equal [1,2,3], Link.ids
    end
    def test_base_addr
      assert Link.base_ip_addr.is_a?(IPAddr)
      assert_equal '13.0.0.0', Link.base_ip_addr.to_s
    end
    def test_new_from_hash
      assert_equal '0.0.0.1', Link.new( :router_id=> 1, :neighbor_id=>2).to_hash[:router_id]
      assert_equal '0.0.0.2', Link.new( :router_id=> 1, :neighbor_id=>2).to_hash[:neighbor_id]
      assert_equal 10, Link.new( :metric => 10).to_hash[:metric]
      assert_equal '10.0.0.0/24', Link.new( :prefix => '10.0.0.0/24').to_hash[:prefix]
    end
    def test_address
      assert_equal '13.0.0.1/30', (l1 = Link.new).local_prefix
      assert_equal '13.0.0.6/30', (l2 = Link.new).remote_prefix
    end
    def test_array_of_links
      arr = (1..10).inject([]) { |arr,i| arr << Link.new(:metric=> i)  }
      assert_equal 10, arr.size
      assert_equal 7, arr[6].metric.to_i
      assert_equal '13.0.0.25/30', arr[6].local_prefix
      assert_equal '13.0.0.26/30', arr[6].remote_prefix
      assert_equal '13.0.0.25', arr[6].local_address
      assert_equal '13.0.0.26', arr[6].remote_address
    end
  end

end
__END__


  #
  #  Created by Jean-Michel Esnault.
  #  Copyright (c) 2008. All rights reserved.
  #

=begin rdoc

=end

module Ospf
  class Link
    include Ospf::Ip

    @count=0
    @base_addr = IPAddr.new(LINK_BASE_ADDRESS)

    def self.base_addr=(addr)
      if addr.is_a?(String) and addr.split('.').size==4
        @base_addr = IPAddr.new(addr)
      elsif addr.is_a?(IPAddr)
        @base_addr = addr
      else
        raise ArgumentError, "expecting dotted ip address or IPAddr object", caller
      end
    end
    class << self
      attr_accessor :count
      attr_reader :base_addr
    end   
    def self.reset_base_addr
      @base_addr = IPAddr.new(LINK_BASE_ADDRESS)
    end
    attr_accessor :rid, :nid

    attr_reader :network, :netmask, :plen, :link_id, :lsas, :metric
    attr_writer :prefix, :lsas

    def initialize(_rid, _nid,  args={})
      raise ArgumentError, "expecting a Hash", caller unless args.is_a?(Hash)
      @link_id = Link.count +=1
      @rid = long2ip(_rid)
      @nid = if _nid.is_a?(Fixnum) or _nid.is_a?(Bignum) then long2ip(_nid) else _nid end
        self.metric=args[:metric] ||= [1,1]
        @prefix = args[:prefix]
        @local_addr, @remote_addr = nil, nil  
        @lsas=[]
      end
      def metric=(_metric)
        if _metric.is_a?(Array) and _metric.size==2
          @metric=_metric
        elsif _metric.is_a?(Fixnum) or _metric.is_a?(Bignum)
          @metric=[_metric]*2
        end
      end
      def metric_to_s
        @metric.collect {|m| m.to_s }.join(',')
      end
      def prefix
        if @prefix.nil?
          @prefix ||= Link.base_addr + (@link_id - 1)  + "/" + Link.base_addr.plen.to_s
          @addr, @source_address, @plen, @network, @netmask = IPAddr.to_ary(@prefix)
        end
        @prefix  
      end  
      def network 
        if @network.nil?
          @addr, @source_address, @plen, @network, @netmask = IPAddr.to_ary(prefix)
        end
        @network
      end
      def netmask 
        if @netmask.nil?
          @addr, @source_address, @plen, @network, @netmask = IPAddr.to_ary(prefix)
        end
        @netmask
      end
      def plen 
        if @plen.nil?
          @addr, @source_address, @plen, @network, @netmask = IPAddr.to_ary(prefix)
        end
        @plen
      end
      def local_address
        @local_addr ||= IPAddr.new(prefix).host(1).split("/")[0]
      end

      def remote_address
        @remote_addr ||= IPAddr.new(prefix).host(2).split("/")[0]
      end

      def to_s
        "Link\##{link_id} from #{rid} to #{nid} network #{@prefix} metric [#{metric_to_s}] "
      end

    end
  end

  module Ospf
    class TE_Link < Link

      @@opaque_id={}
      attr_accessor :te_metric, :bw

      def initialize(rid,nid, args={})
        super(rid,nid,args)
        @bw = args[:bw] ||= 100000000.0
        @te_metric = args[:te_metric] ||= @metric
        @tlvs = link_tlvs
        @te_link_tlv_local = nil
        @te_link_tlv_remote = nil
      end

      def te_lsa_linktlv_local
        @te_link_tlv_local ||= Ospf::TrafficEngineeringLSA.create(rid, @tlvs[0])
      end

      def te_lsa_linktlv_remote
        @te_link_tlv_remote ||= Ospf::TrafficEngineeringLSA.create(nid, @tlvs[1])
      end

      def link_tlvs
        h={}
        h.store(:link_type,1)
        h.store(:link_id,rid)
        h.store(:local_interface_ip_address,local_address)
        h.store(:remote_interface_ip_address,remote_address)
        h.store(:te_metric,te_metric)
        h.store(:max_bw,bw)
        h.store(:max_resv_bw,bw)
        h.store(:unreserved_bw,[bw]*8)
        local = Ospf::LinkTLV.create(h)
        h.store(:link_id,nid)
        h.store(:local_interface_ip_address,remote_address)
        h.store(:remote_interface_ip_address,local_address)
        remote = Ospf::LinkTLV.create(h)
        [local,remote]
      end

      def to_s
        super() + "te_metric #{te_metric}\n"
      end

    end
  end

  module Ospf
    class Link
      include Observable
      def up
        changed
        notify_observers(self,:up)
      end
      def down
        changed
        notify_observers(self,:down)
      end
      def refresh
        changed
        notify_observers(self,:refresh)
      end
      def maxage
        changed
        notify_observers(self,:maxage)
      end
      def flap(uptime,downtime=uptime)
        changed
        notify_observers(self, :flap, uptime, downtime)
      end
    end
  end  

  module Ospf
    class LinkStateDatabase

      def link_add(link, what=:both)
        raise ArgumentError, "expecting a Link or TE_Link object", caller unless link.is_a?(Link)
        addr, source_address, plen, network, netmask = IPAddr.to_ary(link.prefix)
        local = (what == :local or what == :both)
        remote = (what == :remote or what == :both)
        local_exist = has_router_lsa?(link.rid)
        remote_exist = has_router_lsa?(link.nid)
        add_loopback(link.rid) if local
        add_loopback(link.nid) if remote
        if link.is_a?(TE_Link)
          self << link.te_lsa_linktlv_local if local
          self << link.te_lsa_linktlv_remote if remote
        end
        link.add_observer(self)        
        link_flood(link,what,local_exist,remote_exist)

        link.lsas.each do |lsa|
          if (lsa.methods & ["set_link"])==[]
            def lsa.set_link(link)
              @_links=[link]
              def self.set_link(link)
                @_links << link
              end
            end
            def lsa.link?
              @_links
            end
          end
          lsa.set_link(link)
        end
      end

      def link_refresh(link, what=:both)
        raise ArgumentError, "expecting a Link or TE_Link object", caller unless link.is_a?(Link)
        addr, source_address, plen, network, netmask = IPAddr.to_ary(link.prefix)
        local = (what == :local or what == :both)
        remote = (what == :remote or what == :both)
        local_rlsa, remote_rlsa = nil, nil    
        local_rlsa = add_adjacency(link.rid, link.nid, addr.host(1), link.metric)  if local
        remote_rlsa = add_adjacency(link.nid, link.rid, addr.host(2), link.metric) if remote
        link.lsas = [local_rlsa, remote_rlsa].compact
        flood(link.lsas.collect {|l| l.refresh })
        #flood(link.lsas)
      end

      def link_maxage(link, what=:both)
        raise ArgumentError, "expecting a Link or TE_Link object", caller unless link.is_a?(Link)
        addr, source_address, plen, network, netmask = IPAddr.to_ary(link.prefix)
        local = (what == :local or what == :both)
        remote = (what == :remote or what == :both)
        local_rlsa, remote_rlsa = nil, nil    
        local_rlsa = self.lookup(1,link.rid, link.rid).maxage if local
        remote_rlsa = self.lookup(1,link.nid, link.nid).maxage if remote
        link.lsas = [local_rlsa, remote_rlsa].compact
        flood(link.lsas)
      end

      def link_flood(link,what,*refresh)
        link_up(link,what,refresh)
      end

      def link_up(link, what=:both, refresh=[true,true])
        raise ArgumentError, "expecting a Link or TE_Link object", caller unless link.is_a?(Link)
        addr, source_address, plen, network, netmask = IPAddr.to_ary(link.prefix)
        local = (what == :local or what == :both)
        remote = (what == :remote or what == :both)
        local_rlsa, remote_rlsa = nil, nil        
        local_rlsa = add_adjacency(link.rid, link.nid, addr.host(1), link.metric[0])  if local
        remote_rlsa = add_adjacency(link.nid, link.rid, addr.host(2), link.metric[1]) if remote
        link.lsas = [local_rlsa, remote_rlsa]
        lss=[]    
        link.lsas.each_with_index do |lsa,ind|
          next if lsa.nil?
          lss << (refresh[ind] ? lsa.refresh  : lsa) 
        end
        flood(lss)
      end

      def link_down(link, what=:both)
        raise ArgumentError, "expecting a Link or TE_Link object", caller unless link.is_a?(Link)
        addr, source_address, plen, network, netmask = IPAddr.to_ary(link.prefix)

        local = (what == :local or what == :both)
        remote = (what == :remote or what == :both)
        local_rlsa, remote_rlsa = nil, nil

        local_rlsa = remove_adjacency(link.rid, link.nid, addr.host(1)) if local
        remote_rlsa = remove_adjacency(link.nid, link.rid, addr.host(2)) if remote

        #if link.is_a?(TE_Link)
        #  self << link.te_lsa_linktlv_local if local
        #  self << link.te_lsa_linktlv_remote if remote
        #end

        link.lsas = [local_rlsa, remote_rlsa]
        flood(link.lsas.compact.collect {|lsa| lsa.refresh})
      end

      def link_flap(link,uptime,downtime)
        thr=Thread.new(self,link,uptime,downtime) do |lsdb,link,uptime,downtime|
          loop do
            sleep(uptime)   ; link.down
            sleep(downtime) ; link.up
          end    
        end
        def link.set_flap_thread(thr)
          @_flap_thread=thr
        end
        def link.stop_flapping
          @_flap_thread.exit
        end
        link.set_flap_thread(thr)
      end

      def link_update(obj,ev, *others)
        case ev
        when :up ; self.link_up(obj)
        when :down ; self.link_down(obj)
        when :refresh ; self.link_refresh(obj)
        when :maxage ; self.link_maxage(obj)
        when :flap ; self.link_flap(obj,*others)
        end
      end

      def links?
        links=[]
        router_lsas.lsas.each do |lsa|
          lsa.link?.each { |link| links << link } if lsa.respond_to?(:link?)
        end
        links.uniq
      end

      def router_lsas_from_links?
        links?.collect { |lnk| lnk.lsas }.flatten.uniq.compact
      end

    end
  end


  if __FILE__ == $0
    include Ospf

    #  lsdb = LinkStateDatabase.new()
    #  lsdb << Link.new(1,1)
    #  lsa = lsdb.lookup(1,1)
    #  lnk=lsa.link?[0]
    #  puts lnk
    #  lnk.flap(4,2)
    #  sleep(30)
    #  puts "calling lnk.stop_flapping"
    #  lnk.stop_flapping
    #  sleep(10)
    #  lnk.flap(5,1)
    #  sleep(20)

    load "../test/ospf_links_test.rb"
  end

  __END__



  TODO document adding MT to a link
  lsa = lsdb.lookup(:router,'1.1.1.1')
  link = lsa.lookup(1,'2.2.2.2')[0]
  link.metric=200
  link << [33,100]
