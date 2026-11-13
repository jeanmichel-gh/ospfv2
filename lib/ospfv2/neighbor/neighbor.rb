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
require_relative '../neighbor_sm/states'
require_relative '../packet/packets'
require_relative '../ls_db/link_state_database'
require_relative 'neighbor_event_handler'

module OSPFv2

  # One OSPF adjacency, seen from the simulated router: the neighbor state
  # machine, the database exchange, the request list, the inactivity timer
  # and the LSAs this neighbor has not acked yet. What there is one of per
  # segment (transport, hellos, flooding, the lock) is its Interface.
  # docs/design/sim-dr-bdr.md.
  #
  # Neighbor.new without +interface:+ builds an Interface, the whole
  # simulator side of a segment, as it always has:
  #
  #   nbr = Neighbor.new router_id: '1.1.1.1', src_addr: '192.168.1.10/24'
  #   nbr.ls_db = ls_db
  #   nbr.start
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

    # Where the next DD packet starts in the LSDB: the adjacency's own, so
    # two exchanges at once do not share it (REVIEW.md item 5).
    Cursor = Struct.new(:offset)

    include OSPFv2::Common
    include OSPFv2::NeighborState
    include OSPFv2

    InactivityTimer   = Class.new(Timer)
    HelloTimer        = Class.new(PeriodicTimer)
    RxmtIntervalTimer = Class.new(PeriodicTimer)
    RefreshTimer      = Class.new(PeriodicTimer)
    RouterId          = Class.new(Id)
    AreaId            = Class.new(Id)

    # Options (all optional) for a whole simulator side, an Interface:
    #   :router_id      our router id                       ('1.1.1.1')
    #   :src_addr       interface address, '10.0.0.1/24' or '10.0.0.1'
    #   :netmask        interface netmask when src_addr has no prefix length
    #   :area_id        area                                 (0)
    #   :hello_interval / :dead_interval  seconds            (10 / 4 x hello)
    #   :transport      a Transport, default raw IP socket on src_addr
    #   :network_type   :broadcast (default) or :p2p
    #   :interface      device to bind the raw socket to (a String)
    #   :log / :log_fname  IO or file name for traces       ($stdout)
    #   :debug          true for verbose traces
    #
    # An Interface makes its adjacencies with interface: itself and
    # address: the neighbor's address.
    def self.new(arg = {})
      arg[:interface].is_a?(Interface) ? super : Interface.new(arg)
    end

    attr_reader :interface, :inactivity_timer, :dd_rxmt_interval, :neighbor_ip, :neighbor_router_id

    def initialize(arg = {})
      @interface = arg[:interface]
      @neighbor_ip = arg[:address]
      @neighbor_router_id = nil
      # The packet builders here and in the states read these two.
      @router_id = @interface.router_id
      @area_id = @interface.area_id
      @state = NeighborState::Down.new
      @inactivity_timer = InactivityTimer.new(dead_int)
      @ls_req_list = {}
      @dd_cursor = Cursor.new(0)
      @acked = {} # LSA key => the instance this neighbor acked
      @ls_db = nil
    end

    # What the segment holds, the Interface answers.
    %i[hello address netmask hello_int dead_int network_type transport
       synchronize log debug debug? send_packet flood flooding_address point_to_point?
       hello_mismatch start_ls_refresh].each do |m|
      define_method(m) { |*a, &b| @interface.__send__(m, *a, &b) }
    end

    attr_reader :router_id, :area_id

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

    def clear_lsa_request_list
      @ls_req_list = {}
    end

    def ls_request_pending
      @ls_req_list.size
    end

    def change_state(new_state, event = nil)
      @num = (@num || 0) + 1
      old = state
      log 'state change', "#{@neighbor_ip} #{@num}# [#{event}]: #{old} -> #{new_state.class.to_s.split('::').last}"
      @state = new_state
      @interface.adjacency_changed(self, old, state, event)
    end
    alias new_state change_state

    def dd_sequence_number
      @dd_sequence_number = DatabaseDescription.seqn
    end

    # The Interface starts an adjacency when it decides to have one.
    def start
      ev = @interface.ev
      @dd_rxmt_interval = RxmtIntervalTimer.new(5, ev)
      @periodic_rxmt    = RxmtIntervalTimer.new(5, ev)
      @state.start(self)
      self
    end

    # Ends the adjacency: the Interface decided it is no longer wanted, or
    # is stopping.
    def kill(why = 'kill_nbr')
      [@inactivity_timer].each { |t| t&.cancel }
      cancel_adjacency_timers
      @ls_req_list = {}
      new_state NeighborState::Down.new, why unless state == :down
    end

    def running?
      @interface.running?
    end

    # ---- this adjacency's view of the LSDB

    # The exchange will describe every LSA we hold, so each counts as
    # acked by this neighbor; the DD cursor starts again. This is what
    # LinkStateDatabase#reset did when there was one adjacency.
    def reset_lsdb_view
      @dd_cursor.offset = 0
      @acked = @ls_db ? @ls_db.all.to_h { |l| [l.key, instance(l)] } : {}
      @interface.recheck_acks
    end

    def forget_lsdb_view
      @dd_cursor.offset = 0
      @acked = {}
    end

    def acked?(lsa)
      @acked[lsa.key] == instance(lsa)
    end

    # LSAs still to go to this neighbor: not acked by it.
    def pending_lsas
      @ls_db ? @ls_db.all_not_acked.reject { |l| acked?(l) } : []
    end

    def start_periodic_rxmt
      debug '*** about to start periodic rxmt timer ***'
      @periodic_rxmt.cancel
      @periodic_rxmt.start do
        synchronize do
          unless @ls_req_list.empty?
            debug "There are #{@ls_req_list.size} LS Request to re-transmit!"
            send_packet LinkStateRequest.new(area_id: area_id, router_id: router_id, requests: @ls_req_list.keys), @neighbor_ip
          end
          lsas = pending_lsas
          debug "There are #{lsas.size} LSA to re-transmit to #{@neighbor_ip}!"
          # RFC 2328 13.6: retransmissions go directly to the neighbor.
          flood lsas, @neighbor_ip
        end
      end
    end

    def cancel_adjacency_timers
      [@periodic_rxmt, @dd_rxmt_interval].each { |t| t&.cancel }
    end

    def negotiation_done
      @state.negotiation_done
    end

    def exchange_done
      @state.exchange_done(self)
    end

    # A DD says the options our hellos say (RFC 2328 10.8): a router that
    # checks them refuses a DD whose E bit differs.
    def send_dd(dd, rxmt = false)
      dd.options = hello.options.to_i if hello && dd.options.to_i.zero?
      dd_rxmt_interval.cancel
      dd_rxmt_interval.start { synchronize { debug "*** re-transmitting #{dd} ***"; send_packet dd, @neighbor_ip } } if rxmt
      send_packet dd, @neighbor_ip
      @sent_dd = dd
    end

    def to_hash
      {
        address: @neighbor_ip, router_id: @neighbor_router_id&.to_ip, state: state,
        ls_request_pending: @ls_req_list.size
      }
    end

    private

    def instance(lsa)
      [lsa.sequence_number.to_I, lsa.maxaged?]
    end
  end
end

require_relative 'interface'
require_relative 'recv_ospf_packet'
