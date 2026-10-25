#--
# Copyright 2010 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
# This file is part of OSPFv2.
#
# OSPFv2 is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#++

require 'monitor'
require 'ipaddr'
require_relative '../infra/ospf_common'
require_relative '../infra/ospf_constants'
require_relative '../infra/timer'
require_relative '../infra/transport'
require_relative '../neighbor_sm/neighbor_state'
require_relative '../packet/ospf_packet'
require_relative '../ls_db/link_state_database'
require_relative 'neighbor_event_handler'

module OSPFv2

  # One OSPF adjacency, seen from the simulated router.
  #
  #   nbr = Neighbor.new router_id: '1.1.1.1', src_addr: '192.168.1.10/24'
  #   nbr.ls_db = ls_db
  #   nbr.start
  #
  # The neighbor sends hellos, runs the RFC 2328 neighbor state machine,
  # exchanges the database with the router under test and keeps flooding
  # and refreshing the LSAs of ls_db that it originates.
  class Neighbor

    # Writes protocol traces to an IO or a file.
    class Trace
      def initialize(io = $stdout)
        @io = io.is_a?(String) ? File.open(io, 'a') : io
        @io.sync = true if @io.respond_to?(:sync=)
        @lock = Mutex.new
      end

      def trace(s)
        @lock.synchronize { @io << s }
      rescue IOError
        # output closed, drop the trace
      end
    end

    include OSPFv2::Common
    include OSPFv2::NeighborState
    include OSPFv2

    InactivityTimer   = Class.new(Timer)
    HelloTimer        = Class.new(PeriodicTimer)
    RxmtIntervalTimer = Class.new(PeriodicTimer)
    RefreshTimer      = Class.new(PeriodicTimer)
    RouterId          = Class.new(Id)
    AreaId            = Class.new(Id)

    attr_reader :address, :netmask, :inactivity_timer, :hello, :dd_rxmt_interval
    attr_reader :area_id, :neighbor_ip, :neighbor_router_id, :transport, :network_type
    attr_writer :hello_int, :dead_int

    # Options (all optional):
    #   :router_id      our router id                       ('1.1.1.1')
    #   :src_addr       interface address, '10.0.0.1/24' or '10.0.0.1'
    #   :netmask        interface netmask when src_addr has no prefix length
    #   :area_id        area                                 (0)
    #   :hello_interval / :dead_interval  seconds            (10 / 4 x hello)
    #   :transport      a Transport, default raw IP socket on src_addr
    #   :network_type   :broadcast (default) or :p2p
    #   :interface      device to bind the raw socket to
    #   :log / :log_fname  IO or file name for traces       ($stdout)
    #   :debug          true for verbose traces
    def initialize(arg = {})
      @address, @netmask = split_address(arg[:src_addr] || '127.0.0.1', arg[:netmask])
      @router_id = RouterId.new(arg[:router_id] || '1.1.1.1')
      @area_id   = AreaId.new(arg[:area_id] || 0)
      @hello_int = arg[:hello_interval] || arg[:hello_int]
      @dead_int  = arg[:dead_interval]  || arg[:dead_int]
      @interface = arg[:interface]
      @network_type = (arg[:network_type] || :broadcast).to_sym
      @transport = arg[:transport]
      @debug     = arg[:debug]
      @trace     = Trace.new(arg[:log] || arg[:log_fname] || $stdout)
      @lock      = Monitor.new
      @listeners = []

      @state = NeighborState::Down.new
      @inactivity_timer = InactivityTimer.new(dead_int)
      @periodic_hellos  = HelloTimer.new(hello_int)
      @ls_req_list = {}
      @ls_db = nil
      @ev = nil
      @output = false
      build_hello
    end

    def hello_int
      @hello_int ||= 10
    end

    def dead_int
      @dead_int ||= hello_int * 4
    end

    # Every handler, timer callback and user action runs under this lock so
    # the LSDB is never changed by two threads at once.
    def synchronize(&block)
      @lock.synchronize(&block)
    end

    # Called with (old_state, new_state, event) on every state change.
    def on_state_change(&block)
      @listeners << block
      self
    end

    def state
      @state.class.to_s.split('::').last.downcase.to_sym
    end

    def in_state?(*states)
      states.empty? ? state : states.include?(state)
    end

    def full?
      state == :full
    end

    def ls_db
      @ls_db
    end

    def ls_db=(val)
      raise ArgumentError, 'expecting a LinkStateDatabase object!' unless val.is_a?(LSDB::LinkStateDatabase)
      @ls_db = val
    end

    def log(ev, obj)
      if obj.is_a?(String)
        @trace.trace "\n#{Time.now.strftime('%H:%M:%S')} #{ev}: #{obj}"
      else
        s = +"\n#{Time.now.strftime('%H:%M:%S')} (#{state}) #{ev} #{obj.name.to_camel}:\n#{obj}"
        s << "\n " << obj.encode.hexlify.join("\n ") if debug?
        s << "\n"
        @trace.trace s
      end
    end

    def debug?
      @debug || (defined?($debug) && $debug == 1)
    end

    def debug(obj)
      log :debug, obj if debug?
    end

    def clear_lsa_request_list
      @ls_req_list = {}
    end

    def router_id
      @router_id
    end

    def change_state(new_state, event = nil)
      @num = (@num || 0) + 1
      old = state
      log 'state change', "#{@num}# [#{event}]: #{old} -> #{new_state.class.to_s.split('::').last}"
      @state = new_state
      @listeners.each { |l| l.call(old, state, event) }
    end
    alias new_state change_state

    def dd_sequence_number
      @dd_sequence_number = DatabaseDescription.seqn
    end

    def start
      synchronize do
        return self if @output
        @ev ||= NeighborEventHandler.new(self)
        @dd_rxmt_interval = RxmtIntervalTimer.new(5, @ev)
        @periodic_rxmt    = RxmtIntervalTimer.new(5, @ev)
        @periodic_refresh = RefreshTimer.new(60, @ev)
        @transport ||= Transport::RawSocket.new(@address, interface: @interface)
        @transport.start { |bytes, from| @ev.update(:ev_recv, bytes, from) }
        @output = true
        start_periodic_hellos
        @state.start(self)
      end
      self
    end

    def stop
      synchronize do
        [@periodic_hellos, @periodic_rxmt, @periodic_refresh, @dd_rxmt_interval, @inactivity_timer].each { |t| t&.cancel }
        @transport&.stop
        @output = false
        @state.kill_nbr(self)
      end
      self
    end

    def running?
      @output
    end

    # Sends one packet or an Array of packets. Default destination is
    # AllSPFRouters. Was Neighbor#send, which shadowed Object#send.
    def send_packet(packet, dest = OSPFv2::AllSPFRouters)
      return unless @output
      [packet].flatten.compact.each do |p|
        log :snd, p
        @transport.send_packet(p.encode, dest)
      end
    end

    # Where updates and acks go: on a broadcast segment the simulator is a
    # DROther (priority 0) and talks to the DR and BDR (RFC 2328 13.3).
    def flooding_address
      point_to_point? ? AllSPFRouters : AllDRouters
    end

    # Floods +lsas+ in one or more Link State Updates.
    def flood(lsas, dest = flooding_address)
      lsas = [lsas].flatten.compact
      return if lsas.empty?
      send_packet LinkStateUpdate.new_lsas(router_id: @router_id, area_id: @area_id, lsas: lsas), dest
    end

    def start_periodic_hellos
      @periodic_hellos.cancel
      send_packet @hello
      @periodic_hellos.start { synchronize { send_packet @hello } }
    end

    def start_periodic_rxmt
      debug '*** about to start periodic rxmt timer ***'
      @periodic_rxmt.cancel
      @periodic_rxmt.start do
        synchronize do
          unless @ls_req_list.empty?
            debug "There are #{@ls_req_list.size} LS Request to re-transmit!"
            send_packet LinkStateRequest.new(area_id: @area_id, router_id: @router_id, requests: @ls_req_list.keys), @neighbor_ip
          end
          if @ls_db
            lsas = @ls_db.all_not_acked
            debug "There are #{lsas.size} LSA to re-transmit!"
            flood lsas
          end
        end
      end
    end

    def start_ls_refresh
      return unless @ls_db
      debug '*** about to start periodic refresh timer ***'
      @periodic_refresh.cancel
      @periodic_refresh.start do
        synchronize { @ls_db.refresh if in_state? :full, :loading, :exchange }
      end
      nil
    end

    def cancel_adjacency_timers
      [@periodic_refresh, @periodic_rxmt, @dd_rxmt_interval].each { |t| t&.cancel }
    end

    def negotiation_done
      @state.negotiation_done
    end

    def exchange_done
      @state.exchange_done(self)
    end

    def send_dd(dd, rxmt = false)
      dd_rxmt_interval.cancel
      dd_rxmt_interval.start { synchronize { debug "*** re-transmitting #{dd} ***"; send_packet dd, @neighbor_ip } } if rxmt
      send_packet dd, @neighbor_ip
      @sent_dd = dd
    end

    # Hello parameters that must match ours on the segment (RFC 2328 10.5).
    def hello_mismatch(rcv)
      errs = []
      errs << "hello interval #{rcv.hello_interval} != #{hello_int}" if rcv.hello_interval != hello_int
      errs << "dead interval #{rcv.router_dead_interval} != #{dead_int}" if rcv.router_dead_interval != dead_int
      errs << "netmask #{rcv.netmask.to_ip} != #{@netmask}" if rcv.netmask.to_ip != @netmask && !point_to_point?
      errs
    end

    def point_to_point?
      @network_type == :p2p
    end

    def to_hash
      {
        router_id: @router_id.to_ip, area_id: @area_id.to_ip, address: @address, netmask: @netmask,
        hello_interval: hello_int, dead_interval: dead_int, state: state, network_type: @network_type,
        designated_router: @hello.designated_router_id.to_ip,
        neighbor_ip: @neighbor_ip, neighbor_router_id: @neighbor_router_id&.to_ip,
        ls_request_pending: @ls_req_list.size
      }
    end

    private

    def split_address(addr, netmask)
      ip, plen = addr.to_s.split('/')
      mask = if plen then IPAddr.new("#{ip}/#{plen}").netmask
             elsif netmask then IPAddr.new(netmask).to_s
             else '255.255.255.0'
             end
      [ip, mask]
    end

    def build_hello
      @hello = Hello.new(
        router_id: @router_id.to_i,
        area_id: @area_id.to_i,
        netmask: @netmask,
        designated_router_id: '0.0.0.0',
        backup_designated_router_id: '0.0.0.0',
        hello_interval: hello_int,
        router_dead_interval: dead_int,
        options: 2,
        rtr_pri: 0
      )
    end
  end
end

require_relative 'recv_ospf_packet'
