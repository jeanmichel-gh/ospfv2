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


require 'observer'
require 'thread'

module OSPFv2

  class Input
    include Observable

    attr_reader :sock

    def initialize(sock, neighbor, ev_handler)
      super()
      @sock=sock
      @neighbor=neighbor
      add_observer(ev_handler)
      @continue=true
    end

    attr_reader :thread
    
    def our_address
      @neighbor.address
    end

    def stop
      @thread.exit
      @thread.join
    rescue
    end

    def start
      @thread = Thread.new(@sock) do |s|
        Thread.current['name'] = self.class.to_s
        begin
          while @continue
            from, port, data = s.recv
            hdr = header(data)
            if hdr[:ip_proto] == 89 and data[20] == 2
              if from != our_address
                changed and notify_observers(:ev_recv, data, from, port) # * @sock.recv ....
              end
            end
          end
        rescue Exception => e
          p e
        end
      end
    end

    private
    

    def long2ip(ip)
      return ip if ip.is_a?(String)
      [ip].pack('N').unpack('CCCC').collect {|c| c}.join('.') 
    end
    def header(_h)
      h = _h.unpack('CCnnnCCnNN')
      {
        :ip_ver  => h[0] >> 4,
        :ip_hlen => (h[0] & 0xf) <<2,
        :ip_tos  => h[1],
        :ip_length => h[2],
        :ip_id  => h[3],
        :ip_offset => h[4],
        :ip_ttl  => h[5],
        :ip_proto => h[6],
        :ip_csum => h[7],
        :ip_src  => long2ip(h[8]),
        :ip_dst  => long2ip(h[9]),
      }
    end
    
  end

  class OutputQ < Queue
    include Observable

    def initialize(sock, *obs)
      super()
      @sock= sock
      obs.each { |o| self.add_observer(o) }
      @continue = true
    end

    attr_reader :thread

    def stop
      @thread.exit
      @thread.join
    rescue
    end

    def start
      @thread = Thread.new(@sock) do |s|
        Thread.current['name'] = self.class.to_s
        begin
          while @continue 
            el = deq
            @sock.send(*el)
          end
        rescue => e
          p e
        end
      end
    end
  end

end

