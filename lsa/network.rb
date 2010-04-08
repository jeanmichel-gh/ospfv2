
=begin rdoc


A.4.3 Network-LSAs

    Network-LSAs are the Type 2 LSAs.  A network-LSA is originated for
    each broadcast and NBMA network in the area which supports two or
    more routers.  The network-LSA is originated by the network's
    Designated Router.  The LSA describes all routers attached to the
    network, including the Designated Router itself.  The LSA's Link
    State ID field lists the IP interface address of the Designated
    Router.

    The distance from the network to all attached routers is zero.  This
    is why metric fields need not be specified in the network-LSA.  For
    details concerning the construction of network-LSAs, see Section
    12.4.2.


        0                   1                   2                   3
        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |            LS age             |      Options  |      2        |
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
       |                        Attached Router                        |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                              ...                              |



    Network Mask
        The IP address mask for the network.  For example, a class A
        network would have the mask 0xff000000.


    Attached Router
        The Router IDs of each of the routers attached to the network.
        Actually, only those routers that are fully adjacent to the
        Designated Router are listed.  The Designated Router includes
        itself in this list.  The number of routers included can be
        deduced from the LSA header's length field.


=end

require 'ie/id'
require 'lsa/lsa'
module OSPFv2
  
NetworkMask = Class.new(Id)
AttachRouter = Class.new(Id)

class Network < Lsa
  
  attr_reader :network_mask, :attached_routers
  
  def initialize(arg={})
    @network_mask, @attached_routers = nil, []
    super
  end
  
  def encode
    lsa=[]
    @network_mask ||= NetworkMask.new
    @attached_routers ||=[]
    lsa << network_mask.encode
    lsa << attached_routers.collect { |x| x.encode }
    super lsa.join
  end
  
  def attached_routers=(val)
    [val].flatten.each { |x| self << x }
  end
  
  def <<(neighbor)
    @attached_routers ||=[]
    @attached_routers << AttachRouter.new(neighbor)
  end
  
  def parse(s)
    network_mask, attached_routers = super(s).unpack('Na*')
    @network_mask = NetworkMask.new network_mask
    while attached_routers.size>0
      self << attached_routers.slice!(0,4).unpack('N')[0]
    end
  end
  
  # Network:
  #    LsAge: 34
  #    Options:  0x22  [DC,E]
  #    LsType: network_lsa
  #    AdvertisingRouter: 192.168.1.200
  #    LsId: 192.168.1.200
  #    SequenceNumber: 0x80000001
  #    LS checksum:  2dc
  #    length: 32
  #    NetworkMask: 255.255.255.0
  #    AttachRouter: 192.168.1.200
  #    AttachRouter: 193.0.0.0
  def to_s_default(*args)
    super  +
    ['', network_mask, *attached_routers].join("\n   ")
  end
  
  # Network *192.168.1.200    192.168.1.200    0x80000001    98  0x22 0x2dc   32
  #   mask 255.255.255.0
  #   attached router 192.168.1.200
  #   attached router 193.0.0.0
  # 
  def to_s_junos
    super
  end

  def to_s_junos_verbose
    mask = "mask #{network_mask.to_ip}"
    attrs = attached_routers.collect { |ar| "attached router #{ar.to_ip}"}
    super +
    ['', mask, *attrs].join("\n  ")
  end
  
end

class Network
  def self.new_hash(h)
    r = new(h)
    r
  end
end

end

load "../../test/ospfv2/lsa/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

