require 'packet/ospf_packet'
require 'ie/options'

module OSPFv2
  
  class Hello < OspfPacket
    
    DesignatedRouterId        = Class.new(Id)
    BackupDesignatedRouterId  = Class.new(Id)
    Netmask                   = Class.new(Id)
    Neighbor                  = Class.new(Id)
    
    attr_reader :netmask, :designated_router_id, :backup_designated_router_id
    attr_reader :hello_interval, :options, :rtr_pri, :router_dead_interval, :neighbors
    attr_writer_delegate :designated_router_id, :backup_designated_router_id
    
    class Neighbors < Array
    end
    
    def initialize(_arg={})
      arg = _arg.dup
      if arg.is_a?(Hash)
        arg.merge!({:packet_type=>1})
        super arg
        @designated_router_id = DesignatedRouterId.new
        @backup_designated_router_id = BackupDesignatedRouterId.new
        @options = Options.new
        @rtr_pri = 0
        @netmask = Netmask.new
        @hello_interval, @router_dead_interval, @neighbors = 10, 40, []
        set arg
      elsif arg.is_a?(String)
        parse arg
      elsif arg.is_a?(Hello)
        parse arg.encode
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end
    
    def neighbors=(val)
      [val].flatten.each { |x| self << x }
    end
    
    def <<(neighbor)
      @neighbors ||=[]
      @neighbors << Neighbor.new(neighbor) unless has_neighbor?(neighbor)
    end
    
    def add_router_id(hello)
      self << hello.router_id.to_hash
    end
    
    def has_neighbor?(neighbor)
      @neighbors.collect { |n| n.to_i }.find_index(Neighbor.new(neighbor).to_i)
    end
    
    def to_s
      super +
      [@netmask, @options, rtr_pri_to_s, @designated_router_id, @backup_designated_router_id, neighbors_to_s].collect { |x| x.to_s }.join("\n ")
    end
    
    #
    # TODO: have to_s_junos
    #            to_s_cisco
    #  and alias based on command line flag ? alias to_s to_s_junos 
    #
    #  def to_s
    #    s = "\nHello Packet:\n  "
    #    s += @header.to_s
    #    s +="dr: #{dr}, "
    #    s +="bdr: #{bdr},\n  "
    #    s +="helloInt: #{helloInt}, "
    #    s +="deadInt: #{deadInt}, "
    #    s +="options: #{@options.to_s}, "
    #    s +="priority: #{@rtr_prio}, "
    #    s +="netmask: #{netmask}, "
    #    s +="neighbors: #{@neighbors.join(' ')}" 
    #  end
    #
    
    def encode
      packet =[]
      packet << netmask.encode
      packet << [@hello_interval, @options.to_i, @rtr_pri, @router_dead_interval].pack('nCCN')
      packet << @designated_router_id.encode
      packet << @backup_designated_router_id.encode
      packet << neighbors.collect { |x| x.encode }
      super packet.join
    end
    
    private
    
    
    def rtr_pri_to_s
      "RtrPrio: #{@rtr_pri}"
    end
    
    def neighbors_to_s
      ["Neighbors:", neighbors.collect { |x| x.to_s(nil) } ].join("\n  ")
    end
    def router_dead_interval_s
      ["Neighbors:", neighbors.collect { |x| x.to_s(nil) } ].join("\n  ")
    end
    
    def parse(s)
      netmask, @hello_interval, options, @rtr_pri, @router_dead_interval, dr, bdr, neighbors = super(s).unpack('NnCCNNNa*')
      @netmask = Netmask.new netmask
      @options = Options.new options
      @designated_router_id = DesignatedRouterId.new dr
      @backup_designated_router_id = BackupDesignatedRouterId.new bdr
      @neighbors ||=[]
      while neighbors.size>0
        self << neighbors.slice!(0,4).unpack('N')[0]
      end
    end
    
  end
end

load "../../test/ospfv2/packet/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__


A.3.2 The Hello packet

Hello packets are OSPF packet type 1.  These packets are sent
periodically on all interfaces (including virtual links) in order to
establish and maintain neighbor relationships.  In addition, Hello
Packets are multicast on those physical networks having a multicast
or broadcast capability, enabling dynamic discovery of neighboring
routers.

All routers connected to a common network must agree on certain
parameters (Network mask, HelloInterval and RouterDeadInterval).
These parameters are included in Hello packets, so that differences
can inhibit the forming of neighbor relationships.  A detailed
explanation of the receive processing for Hello packets is presented
in Section 10.5.  The sending of Hello packets is covered in Section
9.5.

    0                   1                   2                   3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |   Version #   |       1       |         Packet length         |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                          Router ID                            |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                           Area ID                             |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |           Checksum            |             AuType            |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                       Authentication                          |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                       Authentication                          |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                        Network Mask                           |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |         HelloInterval         |    Options    |    Rtr Pri    |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                     RouterDeadInterval                        |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                      Designated Router                        |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                   Backup Designated Router                    |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                          Neighbor                             |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                              ...                              |


Network mask
    The network mask associated with this interface.  For example,
    if the interface is to a class B network whose third byte is
    used for subnetting, the network mask is 0xffffff00.

Options
    The optional capabilities supported by the router, as documented
    in Section A.2.

HelloInterval
    The number of seconds between this router's Hello packets.

Rtr Pri
    This router's Router Priority.  Used in (Backup) Designated
    Router election.  If set to 0, the router will be ineligible to
    become (Backup) Designated Router.

RouterDeadInterval
    The number of seconds before declaring a silent router down.

Designated Router
    The identity of the Designated Router for this network, in the
    view of the sending router.  The Designated Router is identified
    here by its IP interface address on the network.  Set to 0.0.0.0
    if there is no Designated Router.

Backup Designated Router
    The identity of the Backup Designated Router for this network,
    in the view of the sending router.  The Backup Designated Router
    is identified here by its IP interface address on the network.
    Set to 0.0.0.0 if there is no Backup Designated Router.

Neighbor
    The Router IDs of each router from whom valid Hello packets have
    been seen recently on the network.  Recently means in the last
    RouterDeadInterval seconds.
    
    
A.2 The Options field

   The 24-bit OSPF Options field is present in OSPF Hello packets,
   Database Description packets and certain LSAs (router-LSAs, network-
   LSAs, inter-area-router-LSAs and link-LSAs). The Options field
   enables OSPF routers to support (or not support) optional
   capabilities, and to communicate their capability level to other OSPF
   routers.  Through this mechanism routers of differing capabilities
   can be mixed within an OSPF routing domain.

   An option mismatch between routers can cause a variety of behaviors,
   depending on the particular option. Some option mismatches prevent
   neighbor relationships from forming (e.g., the E-bit below); these
   mismatches are discovered through the sending and receiving of Hello
   packets. Some option mismatches prevent particular LSA types from
   being flooded across adjacencies (e.g., the MC-bit below); these are
   discovered through the sending and receiving of Database Description
   packets. Some option mismatches prevent routers from being included
   in one or more of the various routing calculations because of their
   reduced functionality (again the MC-bit is an example); these
   mismatches are discovered by examining LSAs.

   Six bits of the OSPF Options field have been assigned. Each bit is
   described briefly below. Routers should reset (i.e.  clear)
   unrecognized bits in the Options field when sending Hello packets or
   Database Description packets and when originating LSAs. Conversely,
   routers encountering unrecognized Option bits in received Hello
   Packets, Database Description packets or LSAs should ignore the
   capability and process the packet/LSA normally.


                             1                     2
         0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8  9  0  1  2  3
        -+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+--+--+--+--+--+--+
         | | | | | | | | | | | | | | | | | |DC| R| N|MC| E|V6|
        -+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+--+--+--+--+--+--+

                        The Options field

   V6-bit
     If this bit is clear, the router/link should be excluded from IPv6
     routing calculations. See Section 3.8 of this memo.

   E-bit
     This bit describes the way AS-external-LSAs are flooded, as
     described in Sections 3.6, 9.5, 10.8 and 12.1.2 of [Ref1].

   MC-bit
     This bit describes whether IP multicast datagrams are forwarded
     according to the specifications in [Ref7].

   N-bit
     This bit describes the handling of Type-7 LSAs, as specified in
     [Ref8].

   R-bit
     This bit (the `Router' bit) indicates whether the originator is an
     active router.  If the router bit is clear routes which transit the
     advertising node cannot be computed. Clearing the router bit would
     be appropriate for a multi-homed host that wants to participate in
     routing, but does not want to forward non-locally addressed
     packets.

   DC-bit
     This bit describes the router's handling of demand circuits, as
     specified in [Ref10].


=end
