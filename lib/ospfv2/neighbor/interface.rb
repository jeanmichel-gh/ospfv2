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

module OSPFv2

  # The simulated router's side of one segment: what there is one of per
  # segment, whatever the number of adjacencies. docs/design/sim-dr-bdr.md.
  #
  #   ifc = Neighbor.new router_id: '1.1.1.1', src_addr: '192.168.1.10/24'
  #   ifc.ls_db = ls_db
  #   ifc.start
  #
  # It owns the transport and its event thread, the hello and its timer,
  # the DR and BDR as the other routers' hellos name them, the refresh
  # timer, flooding and the lock. Each adjacency is a Neighbor. On a
  # broadcast segment the simulator is a DROther (priority 0): it is
  # adjacent to the DR and the BDR and stops at 2-Way with the others
  # (RFC 2328 10.4). While no hello names a DR, it is adjacent to the first
  # router it hears, as it always was.
  #
  # Neighbor.new without +interface:+ builds one of these, and it answers
  # what a Neighbor used to answer for the adjacency with the DR: state,
  # full?, neighbor_ip, on_state_change...
  class Interface

    include OSPFv2::Common
    include OSPFv2

    attr_reader :address, :netmask, :router_id, :area_id, :network_type, :hello, :transport, :ev, :ls_db

    # Same options as Neighbor.new has always taken.
    def initialize(arg = {})
      @address, @netmask = split_address(arg[:src_addr] || '127.0.0.1', arg[:netmask])
      @router_id = Neighbor::RouterId.new(arg[:router_id] || '1.1.1.1')
      @area_id   = Neighbor::AreaId.new(arg[:area_id] || 0)
      @hello_int = arg[:hello_interval] || arg[:hello_int]
      @dead_int  = arg[:dead_interval]  || arg[:dead_int]
      @device    = arg[:interface]
      @network_type = (arg[:network_type] || :broadcast).to_sym
      @transport = arg[:transport]
      @debug     = arg[:debug]
      @trace     = Neighbor::Trace.new(arg[:log] || arg[:log_fname] || $stdout)
      @lock      = Monitor.new
      @listeners = []
      @adjacency_listeners = []
      @adjacencies = {} # neighbor address => Neighbor
      @routers = {}     # address => what its last hello said
      @heard = 0
      @output = false
      @facade_state = :down
      @idle = :down # the state shown with no adjacency: as the one Neighbor's was
      @ls_db = nil
      @periodic_hellos = Neighbor::HelloTimer.new(hello_int)
      build_hello
    end

    def hello_int
      @hello_int ||= 10
    end

    def dead_int
      @dead_int ||= hello_int * 4
    end

    attr_writer :hello_int, :dead_int

    def synchronize(&block)
      @lock.synchronize(&block)
    end

    # Called with (old_state, new_state, event) when the state shown for
    # the segment changes: the adjacency with the DR, or the only one.
    def on_state_change(&block)
      @listeners << block
      self
    end

    # Called with (neighbor, old_state, new_state, event) on every
    # adjacency's state change.
    def on_adjacency_change(&block)
      @adjacency_listeners << block
      self
    end

    def ls_db=(val)
      raise ArgumentError, 'expecting a LinkStateDatabase object!' unless val.is_a?(LSDB::LinkStateDatabase)
      @ls_db = val
      @adjacencies.each_value { |n| n.ls_db = val }
    end

    # ---- the segment as one state, for those who read one

    # The adjacency the segment's state is: with the DR, or the only one
    # (point-to-point, or before any hello names a DR).
    def primary
      dr = designated_router
      @adjacencies[dr] || (dr == '0.0.0.0' || point_to_point? ? @adjacencies.values.first : nil)
    end

    def state
      primary&.state || (@output ? @idle : :down)
    end

    def in_state?(*states)
      states.empty? ? state : states.include?(state)
    end

    def full?
      state == :full
    end

    # Any adjacency Full: there is someone to flood to.
    def adjacent?
      @adjacencies.each_value.any?(&:full?)
    end

    def neighbor_ip = primary&.neighbor_ip
    def neighbor_router_id = primary&.neighbor_router_id || @neighbor_router_id
    def inactivity_timer = primary&.inactivity_timer
    def dd_rxmt_interval = primary&.dd_rxmt_interval

    def designated_router = @hello.designated_router_id.to_ip
    def backup_designated_router = @hello.backup_designated_router_id.to_ip

    def adjacencies
      @adjacencies.values
    end

    # The adjacency with the BDR, when there is one.
    def bdr_adjacency
      bdr = backup_designated_router
      bdr == '0.0.0.0' ? nil : @adjacencies[bdr]
    end

    # One row per router heard: its role on the segment, and our state
    # with it (two_way for a router we are not adjacent to).
    def neighbors
      dr = designated_router
      bdr = backup_designated_router
      @routers.sort_by { |_, r| r[:order] }.map do |addr, r|
        role = if point_to_point? then nil
               elsif addr == dr then 'DR'
               elsif addr == bdr then 'BDR'
               else 'DROther'
               end
        adj = @adjacencies[addr]
        state = adj ? adj.state : (@hello.has_neighbor?(r[:router_id]) && r[:sees_us] ? :two_way : :init)
        { router_id: r[:router_id].to_ip, address: addr, role: role, state: state }.compact
      end
    end

    # ---- lifecycle

    def start
      synchronize do
        return self if @output
        @ev ||= NeighborEventHandler.new(self)
        @periodic_refresh ||= Neighbor::RefreshTimer.new(60, @ev)
        @transport ||= Transport::RawSocket.new(@address, interface: @device)
        @transport.start { |bytes, from| @ev.update(:ev_recv, bytes, from) }
        @output = true
        @idle = :attempt
        start_periodic_hellos
        log 'state change', '[start]: down -> Attempt'
        facade_changed('start')
      end
      self
    end

    def stop
      synchronize do
        [@periodic_hellos, @periodic_refresh].each { |t| t&.cancel }
        @adjacencies.values.each { |n| drop_adjacency(n, 'kill_nbr') }
        @transport&.stop
        @output = false
        @idle = :down
        facade_changed('ll_down or kill_nbr')
      end
      self
    end

    def running?
      @output
    end

    # Drives the adjacency with the DR, making one if there is none: what a
    # caller holding the one Neighbor could do. The simulator's tests use
    # it to put the adjacency in a state.
    def change_state(new_state, event = nil)
      dr = designated_router
      (primary || add_adjacency(dr == '0.0.0.0' ? nil : dr)).change_state(new_state, event)
    end
    alias new_state change_state

    # ---- sending

    # Sends one packet or an Array of packets. Default destination is
    # AllSPFRouters.
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

    # One refresh timer for the segment, however many adjacencies.
    def start_ls_refresh
      return unless @ls_db
      debug '*** about to start periodic refresh timer ***'
      @periodic_refresh.cancel
      @periodic_refresh.start do
        synchronize { @ls_db.refresh if @adjacencies.each_value.any? { |n| n.in_state?(:full, :loading, :exchange) } }
      end
      nil
    end

    # ---- receiving

    # Every packet read from the segment, already checked by the event
    # handler.
    def receive(packet, from)
      if packet.area_id.to_i != @area_id.to_i
        log :drop, "#{packet.name} from #{from}: area #{packet.area_id.to_ip} != #{@area_id.to_ip}"
        return
      end
      if packet.router_id.to_i == @router_id.to_i
        log :drop, "#{packet.name} from #{from}: our own router id #{@router_id.to_ip}"
        return
      end
      return recv_hello(packet, from) if packet.is_a?(Hello)

      adj = @adjacencies[from]
      if adj
        adj.receive(packet, from)
      elsif packet.is_a?(LinkStateUpdate) && (p = primary)
        # A DROther floods to AllDRouters; we hear it and take its LSAs,
        # as the simulator always has.
        p.receive(packet, from)
      else
        log :rcv, packet
        debug "*** #{packet.name} from #{from} ignored: not adjacent ***"
      end
    end

    def recv_hello(hello, from)
      log :rcv, hello
      if (errs = hello_mismatch(hello)).any?
        log :drop, "hello from #{from} rejected: #{errs.join(', ')}"
        return
      end
      r = (@routers[from] ||= { order: (@heard += 1) })
      r.merge!(router_id: hello.router_id, dr: hello.designated_router_id.to_ip,
               bdr: hello.backup_designated_router_id.to_ip, at: now, sees_us: hello.has_neighbor?(@router_id))
      elect_from_hellos
      choose_adjacencies(from)
      if (adj = @adjacencies[from])
        adj.recv_hello(hello, from)
      else
        # Another router on the segment: list it in our hellos so it sees
        # 2-Way. It is not adjacent (RFC 2328 10.4).
        @hello.add_router_id hello
      end
      facade_changed("DR is #{designated_router}")
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

    # ---- acks across adjacencies

    # Clears an LSA's flag once every adjacency in Exchange or later has
    # acked that instance. With none, the flag is cleared, as the old
    # LinkStateDatabase#reset did.
    def ack_if_all(hdr)
      return unless @ls_db
      lsa = @ls_db.lookup(hdr)
      return unless lsa
      live = @adjacencies.values.select { |n| n.in_state?(:exchange, :loading, :full) }
      if live.empty?
        lsa.ack
      elsif live.all? { |n| n.acked?(lsa) }
        @ls_db.ls_ack(lsa)
      end
    end

    def recheck_acks
      return unless @ls_db
      @ls_db.all_not_acked.each { |l| ack_if_all(l) }
    end

    # ---- adjacencies

    # A Neighbor calls this on each of its state changes.
    def adjacency_changed(nbr, old, new, why)
      @adjacency_listeners.each { |l| l.call(nbr, old, new, why) }
      facade_changed(why)
    end

    # A Neighbor whose inactivity timer fired: it is gone.
    def adjacency_down(nbr)
      return unless @adjacencies[nbr.neighbor_ip].equal?(nbr)
      @adjacencies.delete(nbr.neighbor_ip)
      @routers.delete(nbr.neighbor_ip)
      @idle = :down
      recheck_acks
      facade_changed('Inactivity Timer')
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

    def to_hash
      p = primary
      {
        router_id: @router_id.to_ip, area_id: @area_id.to_ip, address: @address, netmask: @netmask,
        hello_interval: hello_int, dead_interval: dead_int, state: state, network_type: @network_type,
        designated_router: designated_router,
        neighbor_ip: p&.neighbor_ip, neighbor_router_id: p&.neighbor_router_id&.to_ip,
        ls_request_pending: p ? p.ls_request_pending : 0
      }
    end

    private

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # The DR and BDR, as the live routers' latest hellos name them. We are
    # priority 0, so we never stand ourselves (RFC 2328 9.4); we only
    # follow.
    #
    # While roles change, hellos disagree: a router still names the old DR
    # until its own dead timer fires. A router that names itself is the
    # one to believe, so that comes first; then what the others say.
    def elect_from_hellos
      live = @routers.select { |_, r| r[:at] && now - r[:at] <= dead_int }.sort_by { |_, r| -r[:at] }
      claim = ->(role) { live.find { |addr, r| r[role] == addr }&.first }
      said  = ->(role, but = nil) { live.map { |_, r| r[role] }.find { |a| a != '0.0.0.0' && a != but } }
      dr  = claim.(:dr) || said.(:dr) || '0.0.0.0'
      bdr = live.find { |addr, r| r[:bdr] == addr && addr != dr }&.first || said.(:bdr, dr) || '0.0.0.0'
      @hello.designated_router_id = dr
      @hello.backup_designated_router_id = bdr
    end

    # RFC 2328 10.4, decided on each hello: the DR and the BDR get an
    # adjacency; one that is neither any more loses it.
    def choose_adjacencies(from)
      if point_to_point? || designated_router == '0.0.0.0'
        add_adjacency(from) if @adjacencies.empty?
        return
      end
      wanted = [designated_router, backup_designated_router].reject { |a| a == '0.0.0.0' || a == @address }
      @adjacencies.values.each do |n|
        next if wanted.include?(n.neighbor_ip)
        debug "*** #{n.neighbor_ip} is neither DR nor BDR: no adjacency ***"
        drop_adjacency(n, "#{n.neighbor_ip} is neither DR nor BDR")
      end
      add_adjacency(from) if wanted.include?(from)
    end

    def add_adjacency(addr)
      return @adjacencies[addr] if @adjacencies[addr]
      debug "*** adjacency with #{addr} ***"
      n = Neighbor.new(interface: self, address: addr)
      n.ls_db = @ls_db if @ls_db
      @adjacencies[addr] = n
      n.start
      n
    end

    def drop_adjacency(n, why)
      @adjacencies.delete(n.neighbor_ip)
      @idle = :down
      n.kill(why)
      recheck_acks
    end

    # Tells on_state_change listeners when the segment's state changes, or
    # when another adjacency becomes the DR's (the BDR taking over keeps
    # Full, but the interface link must name the new DR).
    def facade_changed(why)
      new = state
      p = primary
      old = @facade_state
      return if new == old && p.equal?(@facade_primary)
      @facade_state = new
      @facade_primary = p
      @listeners.each { |l| l.call(old, new, why) }
    end

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
