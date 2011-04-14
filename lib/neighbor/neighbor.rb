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


require 'thread'
require 'logger'
require 'infra/ospf_common'
require 'neighbor_sm/neighbor_state'
require 'infra/ospf_socket'
require 'infra/ospf_io'
require 'packet/ospf_packet'
require 'infra/timer'
require 'infra/ospf_constants'
require 'ls_db/link_state_database'

require 'neighbor/neighbor_event_handler'

module OSPFv2
  
  class Neighbor
    
    class Trace
      def initialize(io=$stdout)
        @logger = Logger.new(io)
      end
      def trace(s)
        @logger << s
      end
    end
    
    include OSPFv2::Common
    include OSPFv2::NeighborState
    include OSPFv2
    attr_reader :address, :inactivity_timer, :hello, :dd_rxmt_interval
    
    InactivityTimer = Class.new(Timer)
    HelloTimer = Class.new(PeriodicTimer)
    RxmtIntervalTimer = Class.new(PeriodicTimer)
    RefreshTimer = Class.new(PeriodicTimer)
    RouterId = Class.new(Id)
    AreadId = Class.new(Id)

    attr_writer :hello_int, :dead_int
    
    def initialize(arg={})
      #TODO: accept prefix arg and set @address and @netmask in hello...
      @address = arg[:src_addr] || '127.0.0.1'
      @state = NeighborState::Down.new
      @inactivity_timer = InactivityTimer.new(self.dead_int)
      @periodic_hellos = HelloTimer.new(self.hello_int)
      @router_id= RouterId.new arg[:router_id] || '1.1.1.1'
      @area_id= AreaId.new arg[:aread_id] || '0.0.0.0'
      @lsa_request_list = {}
      @ls_db=nil
      if arg[:log_fname]
        @trace = Trace.new(arg[:log_fname])
      else
        @trace = Trace.new
      end
    end
    
    def hello_int
      @hello_int ||= 10
    end
    def dead_int
      @dead_int ||= hello_int*4
    end
    
    def state
      @state.class.to_s.split('::').last.downcase.to_sym
    end

    def in_state?(*states)
      if states.size==0
        state
      else
        states.include? state
      end
    end
    
    def ls_db=(val)
      raise ArgumentError, "expecting a LinkStateDatabase object!" unless val.is_a?(LSDB::LinkStateDatabase)
      @ls_db=val
    end
    
    def log(ev, obj)
      if obj.is_a?(String)
        @trace.trace "\n#{Time.to_ts} #{ev}: #{obj}"
      else
        s = []
        s << "\n#{Time.to_ts} (#{state}) #{ev} #{obj.name.to_camel}:\n#{obj}"
        s << obj.encode.hexlify.join("\n ") if defined?($debug) and $debug == 1
        s << "\n"
        @trace.trace s.join
      end
    rescue => e
      p e
      raise
    end

    def debug(obj)
      log :debug, obj  if defined? $debug and $debug ==1
    end
    
    def clear_lsa_request_list
      @lsa_request_list={}
    end
    
    def router_id
      hello.router_id
    end

    def change_state(new_state, event=nil)
      @num ||=0
      @num +=1
      log 'state change', "#{@num}\# [#{event}]: #{state} -> #{new_state.class.to_s.split('::').last}"
      @state = new_state
    end
    alias :new_state :change_state
    
    def dd_sequence_number
      @dd_sequence_number = DatabaseDescription.seqn
    end
    def start
      unless @ev
        @ev = NeighborEventHandler.new(self)
        @evQ = Queue.new
      end
      @dd_rxmt_interval = RxmtIntervalTimer.new(5,@ev)
      @periodic_rxmt = RxmtIntervalTimer.new(5,@ev)
      @periodic_refresh = RefreshTimer.new(60,@ev)
      init_sockets @address
      init_io
      start_io
      start_periodic_hellos
      @state.start(self)
      self
    end

    def stop
      debug "*** stopping #{router_id}"
      @periodic_hellos.cancel
      @periodic_rxmt.cancel
      @periodic_refresh.cancel
      stop_io
      close_sockets
    rescue Exception => e
      debug "#{e} while stopping neighor"
    ensure
      @state.kill_nbr(self)
      self
    end
    
    def update(*args)
      @evQ.enq(*args)
    end
    def send(packet, dest=OSPFv2::AllSPFRouters)
      # p "about to send 111111 #{packet.class} "
      # p "@output? #{@output ? true : false} #{packet.class}"
      # p @output
      # p "--------------"
      return unless @output
      case packet
      when Array
        # p "WE HAVE AN ARRAY OF PACKET!"
        packet.each { |p| 
          # p "about to send p 333333 #{p.inspect}"
          # log :snd, p
          @output.enq [p,dest]
        }
      else
        log :snd, packet
        # p "about to send packet 333333 #{packet.inspect}"
        @output.enq [packet,dest]
        # p "about to send 333333 #{packet.inspect}"
      end
    end
    
    # AllSPFRouters = "224.0.0.5"
    # AllDRouters = "224.0.0.6"
    def flood(lsas, dest=AllSPFRouters)
      send LinkStateUpdate.new_lsas(lsas), dest
    end
    
    def start_periodic_hellos
      @periodic_hellos.cancel
      hh = {
        :router_id=> @router_id,
        :netmask=> 0xffffff00, 
        :designated_router_id=> '0.0.0.0',
        :backup_designated_router_id=> '0.0.0.0',
        :helloInt=>hello_int,
        :options=>2,
        :rtr_pri=>0,
        :deadInt=>dead_int,
      }
      @hello = Hello.new(hh)
      @periodic_hellos.start {
        send(@hello)
      }
    end
    
    def start_periodic_rxmt
      debug "*** about to start periodic rxmt timer ***"
      @periodic_rxmt.start {
        if @ls_req_list
          debug "There are #{@ls_req_list.size} LS Request to re-transmit!"
          send LinkStateRequest.new :area_id => @area_id, :router_id=> @router_id, :requests=> @ls_req_list.keys \
                unless @ls_req_list.empty?
        end
        if @ls_db
          lsas = @ls_db.all_not_acked
          debug "There are #{lsas.size} LSA to re-transmit!"
          send LinkStateUpdate.new_lsas  :router_id=> @router_id, 
                                         :area_id => @area_id, :lsas => lsas unless lsas.empty?
        end
      }
    end
    
    def start_ls_refresh
      return unless @ls_db
      debug "*** about to start periodic refresh timer ***"
      @periodic_refresh.start { 
        @ls_db.refresh if in_state? :full, :loading, :exchange 
      }
      nil
    end
    
    
    def negotiation_done
      @state.negotiation_done
    end
    def exchange_done
      @state.exchange_done(self)
    end
    
    def send_dd(dd, rxmt=false)
      dd_rxmt_interval.cancel
      dd_rxmt_interval.start { debug "\n\n\n*** re-transmitting #{dd} ***\n\n\n" ; send dd } if rxmt
      send dd, @neighbor_ip
      @sent_dd = dd
    end

    def method_missing(method, *args, &block)
      if method.to_s =~ /^(recv|unpack)/
        puts %{

          Method missing : #{method} !!!! #{@neighbor_state}

        }
        puts caller.reverse.join("\n")
        raise
      else
        super
      end
    end
    
private
  
    def init_sockets(src_addr)
      begin
        @rsock = RecvSocket.new(src_addr)
        @ssock = SendSocket.new(src_addr)
      rescue(Errno::EPERM) => e
        STDERR.puts "\n**** root permission required, neighbor cannot be started.\n"
        return
      end
    end
    
    def close_sockets
      @rsock.close
      @ssock.close
    rescue
    end
    
    def init_io
      @input = Input.new(@rsock,self, @ev)
      @output = OutputQ.new(@ssock,self, @ev)
    end
    def start_io
      @input.start
      @output.start
    end
    def stop_io
      @input.stop
      @output.stop
    end
    
  end
  
end

require 'neighbor/recv_ospf_packet'

