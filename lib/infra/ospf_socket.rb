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


require 'socket'
require 'ipaddr'
require 'infra/ospf_constants'

module OSPFv2

  class SendSocket
    
    attr_reader :sock
    
    def initialize(src, options={})
      @src = src
      @sock = Socket.open(Socket::PF_INET, Socket::SOCK_RAW, IPPROTO_OSPF)
      @sock.setsockopt(::Socket::IPPROTO_IP, ::Socket::IP_MULTICAST_IF,  IPAddr.new(src).hton)
      add_membership OSPFv2::AllSPFRouters
      add_membership OSPFv2::AllDRouters
    rescue Errno::EPERM
      $stderr.puts "#{e}: You are not root, cannot run: #{$0}!"
      exit(1)
    rescue Errno::EADDRNOTAVAIL
      STDERR.puts "TODO: check if 127/8 and exit if not."
      # for testing with 127/8
    rescue Exception => e
      STDERR.puts "#{e} Cannot Open Socket!"
      exit(1)
    end
    
    #TODO: use all_spf_routers, all_dr_routers, ...
    #     8.1      Sending protocol packets .............................. 58
    
    
    def send_all_spf_routers
      _send_((packet.respond_to?(:encode) ? packet.encode : packet), 0, @sock_addr_all_spf_routers)
    end
    
    def send_all_dr_routers
      _send_((packet.respond_to?(:encode) ? packet.encode : packet), 0, @send_all_dr_routers)
    end
    
    def send_to(packet, dest)
      _send_((packet.respond_to?(:encode) ? packet.encode : packet), 0, Socket.pack_sockaddr_in(0, dest))
    end
    
    def send(packet, dest)
      addr = Socket.pack_sockaddr_in(0, dest)
      @sock.send((packet.respond_to?(:encode) ? packet.encode : packet),0,addr)
    end
    
    def close
      @sock.close unless @sock.closed?
    end
    
    private
    
    def add_membership(group)
      @sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, (IPAddr.new(group).hton + IPAddr.new(@src).hton))
      puts "*** ADDED #{group} membership to Send Socket ***"
    rescue Errno::EADDRNOTAVAIL
    end

    def _send_(bits, sock_addr)
      @sock.send(bits,0,addr)
    end
  end
  
  class RecvSocket
    require 'socket'
    require 'ipaddr'
    attr_reader :sock
    def initialize(src, options={})
      @src=src
      @sock = Socket.open(Socket::PF_INET, Socket::SOCK_RAW,89)
      add_membership OSPFv2::AllSPFRouters
      add_membership OSPFv2::AllDRouters
    end
    def recv(size=8192)
      begin
        data, sender = @sock.recvfrom(size)
        port, host = Socket.unpack_sockaddr_in(sender)
        [host,port,data]
      rescue => e
        STDERR.puts "RSocket recv() error: #{e}"
      end
    end
    def close
      begin ; @sock.close ; rescue ; end
      @sock=nil
    end
    def add_membership(group)
      @sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, (IPAddr.new(group).hton + IPAddr.new(@src).hton))
      puts "*** ADDED #{group} membership to Recv Socket ***"
    rescue Errno::EADDRNOTAVAIL
    end
  end

end
