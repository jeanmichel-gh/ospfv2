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

#> show ospf database summary 
# Area 0.0.0.0:
#    21 Router LSAs
#    1 Network LSAs
#    80 Summary LSAs
# Externals:

require 'set'
require 'ie/id'
require 'lsa/lsa_factory'
require 'ls_db/common'
require 'ls_db/advertised_routers'

module OSPFv2

  module LSDB

  class LinkStateDatabase
    include OSPFv2
    include OSPFv2::Common
    
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
    
    def <<(arg)
      lsa = OSPFv2::Lsa.factory(arg)
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
 
    def to_s
      @ls_db.each { |k,v| puts v }
    end
    
    def to_s_summary
      lsas = []
      lsas << "    OSPF link state database, Area #{area_id.to_ip}"
      lsas << " Type       ID               Adv Rtr           Seq      Age  Opt  Cksum  Len "
       LsType.all.each do |type|
         lsas << (__send__ "all_#{type}").collect { |l| l.to_s_junos  }.join("\n")
       end
      lsas.join("\n")
    end
    
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
  #   puts ls_db.to_s_summary
    
    
    

end
end

require 'ls_db/link_state_database_build'

load "../../test/ospfv2/ls_db/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__


lsa.header_to_s_junos
lsa.header_to_s_cisco

lsa.to_s_summary_cisco
lsa.to_s_summary_xxxx

def to_s_junos_style(lstype='',rtype=' ')
  sprintf("%-7s %-1.1s%-15.15s  %-15.15s  0x%8.8x  %4.0d  0x%2.2x 0x%4.4x %3d", lstype, rtype, lsid, advr, seqn.to_i, lsage, @options.to_i, @csum, @length)
end


    # 
    # def update(obj,ev,*others)
    #   case obj.class.to_s
    #   when /Link/
    #     link_update(obj,ev,*others)
    #   when /External/
    #     external_update(obj,ev,*others)
    #   when /Summary/
    #     summary_update(obj,ev,*others)
    #   end
    # end
    # 
    # 


module Ospf
class LSA
  attr :do_not_refresh, true
  attr :dd_seqn, true
  attr :described, true
  
end
end

require 'constants'
require 'ip'
require 'lsa_header'
require 'lsa_opaque_header'

module Ospf
class LinkStateDatabase < Hash
  include Ospf
  include Ospf::Ip
  
  attr :area, true
  attr :retransmit, true
  attr :aging
  attr :ls_refresh_time, true
  attr :ls_refresh_interval, true
  attr :ls_rxmt_interval, true
  attr :advrs
  attr :neighbor
  attr :next, true
    
  def initialize(arg={:area=>0},&block)
    @area=long2ip(arg[:area])
    @retransmit=true
    @ls_rxmt_interval=5
    @ls_refresh_time=LSRefreshTime
    @ls_refresh_interval=180
    self.aging=true
    @advrs={}
    @next=0
    self.insert(arg[:lsdb]) unless arg[:lsdb].nil?
    @neighbor=nil
    yield unless block.nil?
  end
    

  def reset
    self.lsas.each {|l| l.ack }
    self.next = 0 unless @lsdb.nil?
  end
  
  def refresh?
    select {|k,v| isRefreshable?(v) }.collect { |p| p[1] }
  end  
  
  def __lsas(type=1)
    lsdb = clone  
    lsdb.keys.each { |k| k[0] == type ? [k] : lsdb.remove(k) }
    lsdb
  end
  private :__lsas

  def router_lsas
    __lsas(1)
  end

  def network_lsas
    __lsas(2)
  end

  def summary_lsas
    __lsas(3)
  end

  def asbr_lsas
    __lsas(4)
  end

  def asbr_summary_lsas
    __lsas(4)
  end
  
  def external_lsas
    __lsas(5)
  end
  
  def opaque_te_lsas
    __lsas(10)
  end
  def opaque_lsas
    __lsas(10)
  end
  
  def __lookup__(arg)
    type, lsid, advr=arg
    lsid = long2ip(lsid) if lsid.is_a?(Fixnum) or lsid.is_a?(Bignum)
    advr = long2ip(advr) if advr.is_a?(Fixnum) or advr.is_a?(Bignum)
    self[[type,lsid,advr]]
  end
  private :__lookup__
      
  def lookup(*args)
    if args.size==1 
      if args[0].is_a?(Array) and args[0].size==3
        if args[0][0].is_a?(Symbol)
          case args[0][0]
          when :router ; args[0][0]=1
          when :network  ; args[0][0]=2
          when :summary  ; args[0][0]=3
          when :asbr_summary  ; args[0][0]=4
          when :asbr ; args[0][0]=4
          when :external ; args[0][0]=5
          when :opaqe_link ; args[0][0]=9
          when :opaque_area ; args[0][0]=10
          when :opaque_as ; args[0][0]=11
          end
        end
        # lsdb.lookup([type,lsid,advr])
        # self[args[0]]
        __lookup__(args[0])
      elsif args[0].is_a?(LSA) or args[0].is_a?(LSA_Header)
        # lsdb.lookup(ls)
        self[args[0].key]
      else
        raise ArgumentError, "Invalid argument", caller
      end
    elsif args.size==3
      # lsdb.lookup(type, lsid, advr)
      lookup(args)
    elsif args.size==2
      # lsdb.lookup(type, lsid, lsid)
      lookup([args[0],args[1],args[1]])
    else
      raise ArgumentError, "*** Invalid argument", caller
    end
  end
  
  
  def __to_s
    s = "\nLSDB area: #{@area} - LSRefreshTime: #{@ls_refresh_time} - LsRxmtInt: #{ls_rxmt_interval} - "
    s += "advrs: '#{@advrs.values.join("', '")}'"
    s += "\n"
    s += sort.collect {|p| p[1].to_s }.join("\n")
    s
  end
  private :__to_s
  
  def to_s
    __to_s
  end
  
  def router_lsa?(rid)
    lookup(1,rid)
  end

  def has_router_lsa?(rid)
    ! lookup(1,rid).nil? 
  end
 
  def to_hash
    h= { :area=> @area, :lsdb=> sort.collect {|p| p[1].to_hash }}
    h.store(:retransmit,@retransmit)
    h.store(:ls_rxmt_interval,@ls_rxmt_interval)
    h.store(:ls_refresh_time,@ls_refresh_time)
    h.store(:ls_refresh_interval,@ls_refresh_interval)
    #h.store(:aging,self.aging)
    h.store(:advrs,@advrs.values)
    h
  end
  
  def clear
    refresh?.each { |lsa| flood(lsa.maxage) }
    loop do 
      break if retransmit? == [] 
      STDERR.puts "We have retransmissions..."
      INFO("We have retransmissions... \n#{retransmit?}  \n==\n")
      sleep(2) 
    end
    super()
    @advrs.clear
  end
   
end
end

if __FILE__ == $0    
  load "../test/lsdb_test.rb"
end
