
=begin rdoc
A.3.3 The Database Description packet

Database Description packets are OSPF packet type 2.  These packets
are exchanged when an adjacency is being initialized.  They describe
the contents of the link-state database.  Multiple packets may be
used to describe the database.  For this purpose a poll-response
procedure is used.  One of the routers is designated to be the
master, the other the slave.  The master sends Database Description
packets (polls) which are acknowledged by Database Description
packets sent by the slave (responses).  The responses are linked to
the polls via the packets' DD sequence numbers.

0                   1                   2                   3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Version #   |       2       |         Packet length         |
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
|         Interface MTU         |    Options    |0|0|0|0|0|I|M|MS
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     DD sequence number                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+-                                                             -+
|                                                               |
+-                      An LSA Header                          -+
|                                                               |
+-                                                             -+
|                                                               |
+-                                                             -+
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                              ...                              |


The format of the Database Description packet is very similar to
both the Link State Request and Link State Acknowledgment packets.
The main part of all three is a list of items, each item describing
a piece of the link-state database.  The sending of Database
Description Packets is documented in Section 10.8.  The reception of
Database Description packets is documented in Section 10.6.

Interface MTU
The size in bytes of the largest IP datagram that can be sent
out the associated interface, without fragmentation.  The MTUs
of common Internet link types can be found in Table 7-1 of
[Ref22]. Interface MTU should be set to 0 in Database
Description packets sent over virtual links.

Options
The optional capabilities supported by the router, as documented
in Section A.2.

I-bit
The Init bit.  When set to 1, this packet is the first in the
sequence of Database Description Packets.

M-bit
The More bit.  When set to 1, it indicates that more Database
Description Packets are to follow.

MS-bit
The Master/Slave bit.  When set to 1, it indicates that the
router is the master during the Database Exchange process.
Otherwise, the router is the slave.

DD sequence number
Used to sequence the collection of Database Description Packets.
The initial value (indicated by the Init bit being set) should
be unique.  The DD sequence number then increments until the
complete database description has been sent.

The rest of the packet consists of a (possibly partial) list of the
link-state database's pieces.  Each LSA in the database is described
by its LSA header.  The LSA header is documented in Section A.4.1.
It contains all the information required to uniquely identify both
the LSA and the LSA's current instance.


=end

require 'packet/ospf_packet'
require 'ie/interface_mtu'
require 'ie/options'
require 'lsa/lsa'
require 'ls_db/link_state_database'

module OSPFv2
  class DatabaseDescription < OspfPacket

    attr_reader :options, :ls_db, :interface_mtu, :dd_sequence_number

    attr_checked :imms do |x|
      (0..7) === x
    end
    attr_checked :dd_sequence_number do |x|
      (0..0xffffffff) === x
    end
    alias :dd_seqn  :dd_sequence_number 
    alias :dd_seqn= :dd_sequence_number=

    def initialize(_arg={})
      arg = _arg.dup
      @interface_mtu = InterfaceMtu.new
      @options = Options.new
      @imms, @dd_sequence_number, @number_of_lsa=0, 0, nil

      if arg.is_a?(Hash)
        arg.merge!({:packet_type=>:dd})
        super arg
      elsif arg.is_a?(String)
        parse arg
      elsif arg.is_a?(DatabaseDescription)
        parse arg.encode
      else
        raise ArgumentError, "Invalid argument", caller
      end
    end

    def to_s
      s = super
      s+= [interface_mtu, options, imms_to_s, dd_sequence_number_to_s].collect { |x| x.to_s }.join("\n ")
      s+= (['']+(@lsas.collect { |x| x.header_to_s })).join("\n ") if @lsas
      s
    end
    def to_s_short
      "I|M|MS: [#{[imms].pack('C').unpack('B8')[0][5..7]}] SEQN: #{dd_sequence_number}"
    end
    def encode
      packet =[]
      packet << @interface_mtu.encode
      packet << [options.to_i, imms, dd_sequence_number].pack('CCN')
      packet << @lsas.collect { |x| x.encode.slice(0,20) }.join if @lsas
      super packet.join
    end
    
    def options=(val)
      @options = Options.new(val)
    end
    
    def more
      @imms |= 2
    end
    
    def no_more
      @imms &= ~2
    end
    
    def master 
      @imms |= 1
    end
    alias :is_master :master
    
    def init 
      @imms |= 4
    end
    alias :in_init :init
    
    def more?
      imms & 2 == 2
    end
    
    def master?
      imms & 1 == 1
    end
    
    def init?
      imms & 4 == 4
    end
    
    alias :seqn :dd_sequence_number
    alias :seqn= :dd_sequence_number=
    
    def each
      @lsas.each do |lsa|
        yield lsa
      end
    end
    
    private
    
    def imms_to_s
      "I|M|MS: #{imms} [#{[imms].pack('C').unpack('B8')[0][5..7]}]"
    end
    
    def dd_sequence_number_to_s
      "DD sequence number: #{dd_sequence_number}"
    end
    
    def parse(s)
      interface_mtu, options, @imms, @dd_sequence_number, headers = super(s).unpack('nCCNa*')
      self.options = Options.new options
      @interface_mtu = InterfaceMtu.new interface_mtu
      @lsas ||=[]
      while headers.size>0
        lsa = Lsa.new headers.slice!(0,20)
        @lsas <<lsa
      end
    end
    
    def number_of_lsa
      #FIXME: rename interface mtu method...
      @number_of_lsa ||=interface_mtu.n0flsa
    end
    
    def set(arg)
      super
      if arg[:ls_db].is_a?(OSPFv2::LSDB::LinkStateDatabase)
        ls_db = arg[:ls_db]
        @lsas = ls_db.lsas[ls_db.offset, number_of_lsa] ||=[]
        ls_db.offset += number_of_lsa
        self.more if ls_db.size > ls_db.offset
      end
    end
    
  end
end

load "../../test/ospfv2/packet/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
