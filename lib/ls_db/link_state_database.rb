#
#  Created by Jean-Michel Esnault.
#  Copyright (c) 2008. All rights reserved.
#

=begin rdoc

12.2.  The link state database
  
    A router has a separate link state database for every area to
    which it belongs. All routers belonging to the same area have
    identical link state databases for the area.
    
    The databases for each individual area are always dealt with
    separately.  The shortest path calculation is performed
    separately for each area (see Section 16).  Components of the
    area link-state database are flooded throughout the area only.
    Finally, when an adjacency (belonging to Area A) is being
    brought up, only the database for Area A is synchronized between
    the two routers.
    
    The area database is composed of router-LSAs, network-LSAs and
    summary-LSAs (all listed in the area data structure).  In
    addition, external routes (AS-external-LSAs) are included in all
    non-stub area databases (see Section 3.6).
    
    An implementation of OSPF must be able to access individual
    pieces of an area database.  This lookup function is based on an
    LSA's LS type, Link State ID and Advertising Router.[14] There
    will be a single instance (the most up-to-date) of each LSA in
    the database.  The database lookup function is invoked during
    the LSA flooding procedure (Section 13) and the routing table
    calculation (Section 16).  In addition, using this lookup
    function the router can determine whether it has itself ever
    originated a particular LSA, and if so, with what LS sequence
    number.
    
    An LSA is added to a router's database when either a) it is
    received during the flooding process (Section 13) or b) it is
    originated by the router itself (Section 12.4).  An LSA is
    deleted from a router's database when either a) it has been
    overwritten by a newer instance during the flooding process
    (Section 13) or b) the router originates a newer instance of one
    of its self-originated LSAs (Section 12.4) or c) the LSA ages
    out and is flushed from the routing domain (Section 14).
    Whenever an LSA is deleted from the database it must also be
    removed from all neighbors' Link state retransmission lists (see
    Section 10).
    
=end

require 'set'
require 'ie/id'
require 'lsa/lsa_factory'
require 'ls_db/common'
require 'ls_db/advertised_routers'

require 'infra/to_s'

module OSPFv2

  module LSDB

  class LinkStateDatabase
    include OSPFv2
    include OSPFv2::Common
    include TO_S
    
    AreaId = Class.new(OSPFv2::Id)
    
    attr_reader :area_id
    attr_writer_delegate :area_id
    
    attr_reader :advertised_routers
    attr_accessor :offset, :ls_refresh_interval
    
    def initialize(arg={})
      @ls_db = Hash.new
      @area_id = nil
      @advertised_routers= AdvertisedRouters.new
      @ls_refresh_interval=180
      @offset=0
      set arg
    end
    
    def ls_refresh_time
      @ls_refresh_time ||= LSRefreshTime
    end
    
    def ls_refresh_time=(val)
      @ls_refresh_time=val
    end
    
    def proxied?(router_id)
      advertised_routers.has?(router_id)
    end
    
    def all
      @ls_db.values
    end
    alias :lsas :all
    
    #TODO: add opaque and external type 7
    LsType.all.each do |type|
      define_method("all_#{type}") do
        @ls_db.find_all { |k,v| k[0]== LsType.to_i(type) }.collect { |k,v| v  }.sort_by { |l| l.advertising_router.to_i  }
      end
    end
    
    def all_proxied
      @ls_db.values.find_all { |lsa| advertised_routers.has? lsa.advertising_router }
    end
    
    def each
      @ls_db.values.each do |lsa|
        yield lsa
      end
    end
    
    def ls_db=(arg)
      [arg].flatten.each { |l| self << l }
    end
    
    def keys
      @ls_db.keys
    end
    
    def <<(lsa)
      lsa = OSPFv2::Lsa.factory(lsa) unless lsa.is_a?(Lsa)
      @ls_db.store(lsa.key,lsa)
      lsa
    end
        
    def ls_ack(lsa)
      
      lsa = lookup(lsa)
      if lsa
        if lsa.maxaged?
          @ls_db.delete(lsa.key)
        else
          @ls_db[lsa.key].ack
        end
      end
      
    end

    def to_hash
      h= { :area=> @area_id.to_ip }
      h.store :ls_db, @ls_db.sort.collect {|p| p[1].to_hash }
      h.store :advertised_routers, advertised_routers.routers
      h.store :ls_refresh_time, ls_refresh_time
      h.store :ls_refresh_interval, ls_refresh_interval
      
      # h.store(:retransmit,@retransmit)
      # h.store(:ls_rxmt_interval,@ls_rxmt_interval)
      # h.store(:aging,self.aging)
      h
    end
    
    def find_router_lsa(router_id)
      lookup(1,router_id)
    end
    def find_asbr_sum(advertising_router)
      lookup(4,advertising_router)
    end
    
    def lookup(*args)
      if args.size==1
        if args[0].is_a?(Array) and args[0].size==3
          if args[0][0].is_a?(Symbol)
            args[0][0] = LsType.to_i(args[0][0])
          end
          args[0][1] = id2i(args[0][1])
          args[0][2] = id2i(args[0][2])
          # lsdb.lookup([type,lsid,advr])
          # self[args[0]]
          @ls_db[args[0]]
        elsif args[0].is_a?(Lsa)
          # ls_db.lookup(lsa)
          @ls_db[args[0].key]
        else
          raise ArgumentError, "Invalid argument, #{args.inspect}"
        end
      elsif args.size==3
        # lsdb.lookup(type, lsid, advr)
        lookup(args)
      elsif args.size==2
        # lsdb.lookup(type, lsid, lsid)
        lookup([args[0],args[1],args[1]])
      else
        raise ArgumentError, "*** Invalid argument, #{args.inspect}"
      end
    end
    
    
    def refresh
      all.find_all {|l| l.refresh(ls_refresh_time) }
    end 
    
    def reset
      each {|lsa| lsa.ack }
      @offset=0
    end
 
    def to_s_default
      s = []
      s << "    OSPF link state database, Area #{area_id.to_ip}"
      s << "Age  Options  Type    Link-State ID   Advr Router     Sequence   Checksum  Length"
       LsType.all.each do |type|
         s << (__send__ "all_#{type}").collect { |l| l.to_s  }
       end
      s.join("\n")
    end
    
    def to_s_junos(verbose=false)
      lsas = []
      lsas << "    OSPF link state database, Area #{area_id.to_ip}"
      lsas << " Type       ID               Adv Rtr           Seq      Age  Opt  Cksum  Len "
       LsType.all.each do |type|
         lsas << "    OSPF AS SCOPE link state database"  if type == :external
         lsas << (__send__ "all_#{type}").collect { |l| 
           if verbose
             l.to_s_junos_verbose 
           else 
             l.to_s_junos
           end
         }
       end
      lsas.join("\n")
    end
    alias :to_j :to_s_junos
    
    def [](*key)
      lookup(*key)
    end
    
    def size
      @ls_db.size
    end
    
    def all_not_acked
     all.find_all { |l| ! l.ack? }
    end
    
    def method_missing(method, *args, &block)
      super
    end
    
    def refresh
      all.find_all {|l| l.refresh(advertised_routers, ls_refresh_time) }
    end 
    
    def ls_refresh?(ls)
      rt = ls_refresh_time
      ls.instance_eval { refresh?(rt) }
    end
    
    def recv_link_state_update(link_state_update)
      link_state_update.each do |lsa|
        if advertised_routers.has?(lsa.advertising_router)
          if @ls_db.key? lsa.key
            @ls_db[lsa.key].force_refresh(lsa.sequence_number)
          else
            @ls_db.store(lsa.key,lsa)
            lsa.maxage
          end
        else
          if lsa.maxaged?
            @ls_db.delete lsa.key
          else
            @ls_db.store(lsa.key,lsa)
            # TBD: remove lsa from lsr_list
          end
        end
      end 
    end
    
    def has?(obj)
      lookup(obj)
    end
      
    
    def recv_dd(dd, ls_req_list)
      raise ArgumentError, "lss nil" unless ls_req_list
      dd.each { |dd_lsa|
        if advertised_routers.has?(dd_lsa.advertising_router)
          our_lsa = lookup(dd_lsa)
          if our_lsa and (our_lsa <=> dd_lsa)
            our_lsa.force_refresh(dd_lsa.sequence_number)
          end
        else 
          ls_req_list.store(dd_lsa.key,0)
        end
      }
      nil
    end
        
    private
    
    def lsa_types
      [:router, :network, :summary, :asbr_summary, :as_external]
    end
    
    def id2i(id)
      return id if id.is_a?(Integer)
      IPAddr.new(id).to_i
    end
    def id2ip(id)
      return id if id.is_a?(String)
      IPAddr.create(id).to_s
    end
    
  end

   #   
   # @ls_db = []
   # @ls_db <<  {
   #   :sequence_number=>2147483650,
   #   :advertising_router=>"1.2.0.0",
   #   :ls_id=>"0.0.4.5",
   #   :nwveb=>1, 
   #   :ls_type=>:router_lsa,
   #   :options=> 0x21,
   #   :ls_age=>10,
   #   :links=>[
   #     {
   #       :link_id=>"1.1.1.1", 
   #       :link_data=>"255.255.255.255", 
   #       :router_link_type=>:point_to_point,
   #       :metric=>11, 
   #       :mt_metrics=>[ {:id=>1, :metric=>11}, {:id=>2, :metric=>22} ]
   #     },
   #     {
   #       :link_id=>"1.1.1.2", 
   #       :link_data=>"255.255.255.255", 
   #       :router_link_type=>:point_to_point,
   #       :metric=>12, 
   #       :mt_metrics=>[]
   #     }
   #   ],
   #   }
   #     
   #   
   #   ls_db = LinkStateDatabase.new :area_id=> 1, :ls_db => @ls_db
   #   puts ""
   #   puts ls_db.to_s_junos
   #      
    
    

end
end

require 'ls_db/link_state_database_build'

load "../../../test/ospfv2/ls_db/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

