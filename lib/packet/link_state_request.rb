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


A.3.4 The Link State Request packet

    Link State Request packets are OSPF packet type 3.  After exchanging
    Database Description packets with a neighboring router, a router may
    find that parts of its link-state database are out-of-date.  The
    Link State Request packet is used to request the pieces of the
    neighbor's database that are more up-to-date.  Multiple Link State
    Request packets may need to be used.

    A router that sends a Link State Request packet has in mind the
    precise instance of the database pieces it is requesting. Each
    instance is defined by its LS sequence number, LS checksum, and LS
    age, although these fields are not specified in the Link State
    Request Packet itself.  The router may receive even more recent
    instances in response.

    The sending of Link State Request packets is documented in Section
    10.9.  The reception of Link State Request packets is documented in
    Section 10.7.

        0                   1                   2                   3
        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |   Version #   |       3       |         Packet length         |
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
       |                          LS type                              |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                       Link State ID                           |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                     Advertising Router                        |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                              ...                              |



    Each LSA requested is specified by its LS type, Link State ID, and
    Advertising Router.  This uniquely identifies the LSA, but not its
    instance.  Link State Request packets are understood to be requests
    for the most recent instance (whatever that might be).

=end

require 'packet/ospf_packet'
module OSPFv2
  class LinkStateRequest < OspfPacket
    
    attr_reader :requests
    
    def initialize(arg={})
      @requests=[]
      if arg.is_a?(String)
        parse arg
      elsif arg.is_a?(Hash)
        arg.merge! :packet_type=>3
        super arg
      elsif arg.is_a?(self)
        parse arg.encode
      else
        raise ArgumentError, "Invalid argument"
      end
    end
    
    def <<(req)
      @request << req
    end
    
    def encode
      requests = []
      requests << @requests.collect { |lsa| lsa.pack('NNN') }.join
      super requests.join
    end
    
    def parse(s)
      requests = super(s)
      while requests.size>0
        @requests << requests.slice!(0,12).unpack('NNN')
      end
    end
    
    def to_s
      s = []
      s << super
      s << @requests.collect { |x| 
        "LS type #{ls_type_to_s(x[0])} Link State ID #{ls_id_to_s(x[1])} Advertising Router #{advr_to_s(x[2])}"
      }.join("\n ")
      s.join("\n ")
    end
    
    def to_lsu(ls_db, arg={})
      LinkStateUpdate.new_lsas arg.merge(:lsas => collect { |req| ls_db[req] })
    end
    
    private
    
    def collect
      @requests.collect do |r|
        yield r
      end
    end
    
    def ls_type_to_s(ls_type)
      LsType.to_sym(ls_type)
    end
    
    def ls_id_to_s(id)
      IPAddr.create(id).to_s
    end
    
    def advr_to_s(id)
      IPAddr.create(id).to_s
    end
    
  end

end

load "../../../test/ospfv2/packet/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
