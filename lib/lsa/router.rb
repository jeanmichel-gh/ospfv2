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
A.4.2 Router-LSAs

Router-LSAs are the Type 1 LSAs.  Each router in an area originates
a router-LSA.  The LSA describes the state and cost of the router's
links (i.e., interfaces) to the area.  All of the router's links to
the area must be described in a single router-LSA.  For details
concerning the construction of router-LSAs, see Section 12.4.1.


0                   1                   2                   3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|            LS age             |     Options   |       1       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Link State ID                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Advertising Router                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     LS sequence number                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         LS checksum           |             length            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|    0    |V|E|B|        0      |            # links            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Link ID                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Link Data                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|     Type      |     # TOS     |            metric             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                              ...                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|      TOS      |        0      |          TOS  metric          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Link ID                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Link Data                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                              ...                              |



In router-LSAs, the Link State ID field is set to the router's OSPF
Router ID. Router-LSAs are flooded throughout a single area only.

bit V
When set, the router is an endpoint of one or more fully
adjacent virtual links having the described area as Transit area
(V is for virtual link endpoint).

bit E
When set, the router is an AS boundary router (E is for
external).

bit B
When set, the router is an area border router (B is for border).

# links
The number of router links described in this LSA.  This must be
the total collection of router links (i.e., interfaces) to the
area.


The following fields are used to describe each router link (i.e.,
interface). Each router link is typed (see the below Type field).
The Type field indicates the kind of link being described.  It may
be a link to a transit network, to another router or to a stub
network.  The values of all the other fields describing a router
link depend on the link's Type.  For example, each link has an
associated 32-bit Link Data field.  For links to stub networks this
field specifies the network's IP address mask.  For other link types
the Link Data field specifies the router interface's IP address.


Type
A quick description of the router link.  One of the following.
Note that host routes are classified as links to stub networks
with network mask of 0xffffffff.




Type   Description
__________________________________________________
1      Point-to-point connection to another router
2      Connection to a transit network
3      Connection to a stub network
4      Virtual link




Link ID
Identifies the object that this router link connects to.  Value
depends on the link's Type.  When connecting to an object that
also originates an LSA (i.e., another router or a transit
network) the Link ID is equal to the neighboring LSA's Link
State ID.  This provides the key for looking up the neighboring
LSA in the link state database during the routing table
calculation. See Section 12.2 for more details.



Type   Link ID
______________________________________
1      Neighboring router's Router ID
2      IP address of Designated Router
3      IP network/subnet number
4      Neighboring router's Router ID




Link Data
Value again depends on the link's Type field. For connections to
stub networks, Link Data specifies the network's IP address
mask. For unnumbered point-to-point connections, it specifies
the interface's MIB-II [Ref8] ifIndex value. For the other link
types it specifies the router interface's IP address. This
latter piece of information is needed during the routing table
build process, when calculating the IP address of the next hop.
See Section 16.1.1 for more details.



# TOS
The number of different TOS metrics given for this link, not
counting the required link metric (referred to as the TOS 0
metric in [Ref9]).  For example, if no additional TOS metrics
are given, this field is set to 0.

metric
The cost of using this router link.


Additional TOS-specific information may also be included, for
backward compatibility with previous versions of the OSPF
specification ([Ref9]). Within each link, and for each desired TOS,
TOS TOS-specific link information may be encoded as follows:

TOS IP Type of Service that this metric refers to.  The encoding of
TOS in OSPF LSAs is described in Section 12.3.

TOS metric
TOS-specific metric information.



NSSA:

+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  0  Nt|W|V|E|B|        0      |            # links            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+


bit W
When set, the router is a wild-card multicast receiver (W is
for wild).

  bit Nt
  When set, the router is an NSSA border router that is
  unconditionally translating Type-7 LSAs into Type-5 LSAs (Nt
  stands for NSSA translation).  Note that such routers have
  their NSSATranslatorRole area configuration parameter set to
  Always.  (See Appendix D and Section 3.1.)


=end

require 'lsa/lsa'
require 'ie/router_link'
require 'ie/router_link_factory'

module OSPFv2

  class Router < Lsa
    
    attr_reader :links, :nwveb
    
    def initialize(arg={})
      super
      @links=[]
      @nwveb ||=0
      @ls_type = LsType.new(:router_lsa)
      
      # arg.merge!({:ls_type => 1}) if arg.is_a?(Hash)
      [[:abr,1],[:asbr,2],[:vl,4],[:wild,8],[:nssa,16]].each { |x| def_bit(*x) }
    end
    
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |  0  Nt|W|V|E|B|        0      |            # links            |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    def encode
      lsa = []
      lsa << [@nwveb,0,@links.size].pack('CCn')
      lsa << @links.collect { |x| x.encode } unless @links.empty?
      super(lsa.join)
    end
    
    def links=(val)
      [val].flatten.each { |x| self << x }
    end
    
    def <<(link)
      @links << RouterLink.factory(link)
      self
    end
    
    def number_of_link
      @links.size
    end
    
    def parse(s)
      @nwveb, _, nlinks, links = super(s).unpack('CCna*')
      while links.size>0
        ntos= links[9..10].unpack('C')[0]
        self << links.slice!(0,12+ntos*4)
      end
    end
    
    def to_s_default
       super  +
       ['', nwveb_to_s, *links.collect {|x| x.to_s }].join("\n   ")
     end

     def to_s_junos
       super
     end

     def to_s_junos_verbose
       link_hdr = "  bits 0x#{nwveb.to_i}, link count #{links.size}"
       links_to_s = links.collect {|link| link.to_s_junos }
       super + ['', link_hdr, *links_to_s].join("\n")
     end

    def has_link?(*args)
      self[*args] ? true : false
    end
    
    def [](*args)
      if args.size==1
        @links[*args]
      else
        ltype, link_id = args_to_key(*args)
        link = links.find_all { |x| (x.router_link_type.to_i == ltype) and (x.link_id.to_hash == link_id) }
        link.empty? ? nil : link[0]
      end
    end
    alias :lookup :[]
    
    def delete(*args)
      ltype, link_id = args_to_key(*args)
      links.delete_if { |x| x.router_link_type.to_i == ltype and x.link_id.to_hash == link_id }
    end
    
    def each
      links.each { |x| yield(x)  }
    end
    
    #FIXME: make link_id an integer ...
    def args_to_key(*args)
      if args.size==1 and args[0].is_a?(RouterLink)
        [args[0].router_link_type.to_i, args[0].link_id.to_hash]
      elsif args.size==2 and args[0].is_a?(Symbol) and args[1].is_a?(String)
        [RouterLinkType.to_i(args[0]), args[1]]
      elsif args.size==2 and args[0].is_a?(Fixnum) and args[1].is_a?(String)
        args
      end
    end
    
   private
    
    def nwveb_to_s
      "|Nt|W|V|E|B| " + [@nwveb].pack('C').unpack('B8')[0]
    end
    
    def def_bit(name, pos)
      self.class.class_eval {
      define_method("set_#{name}") do
        @nwveb = @nwveb | pos
      end
      define_method("unset_#{name}") do
        @nwveb = @nwveb & ~pos
      end
      define_method("#{name}?") do
        @nwveb & pos>0
      end
    }
    end

  end
  
  # 
  # rlsa = Router.new( :advertising_router => '1.1.1.1', :ls_id => '2.2.2.2')
  # p rlsa.advertising_router
  # p rlsa.ls_id
  # 
  # $style=:default
  # 
  # puts rlsa

  
  class Router
    def self.new_hash(h)
      r = new(h)
      r.instance_eval { @nwveb = h[:nwveb] || 0}
      h[:links].each { |l| r << l } if h[:links]
      r
    end
  end
  
end

load "../../../test/ospfv2/lsa/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
