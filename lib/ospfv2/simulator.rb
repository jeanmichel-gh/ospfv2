# frozen_string_literal: true

require 'monitor'
require 'time'
require 'stringio'
require_relative '../ospfv2'
require_relative 'topology'

module OSPFv2
  # Runs a Topology: builds its link state database, brings up the
  # neighbor towards the device under test and applies live changes
  # (links up and down, flaps, refreshes) by re-originating and
  # flooding the LSAs they touch.
  #
  #   sim = OSPFv2::Simulator.new(OSPFv2::Topology.load('lab.yml'))
  #   sim.start
  #   sim.link_down('r1c1--r1c2')
  class Simulator
    Event = Struct.new(:seq, :time, :kind, :text, keyword_init: true)

    # A topology link and the LSDB link that implements it.
    class LinkState
      attr_reader :id, :spec, :lsdb_link

      def initialize(id, spec, lsdb_link)
        @id = id
        @spec = spec
        @lsdb_link = lsdb_link
        @up = spec.up?
      end

      def name = spec.name
      def up? = @up
      def up! = (@up = true)
      def down! = (@up = false)

      def to_h
        { id: id, name: name, from: spec.from, to: spec.to, metric: spec.metric, up: @up,
          network: lsdb_link.network_to_s }
      end
    end

    MAX_EVENTS = 500

    attr_reader :topology, :ls_db, :neighbor, :links, :started_at

    # transport: optional Transport (default raw socket on the interface)
    # log:       IO or file name for protocol traces (default: discard)
    def initialize(topology, transport: nil, log: nil, debug: false)
      @topology = topology
      @lock = Monitor.new
      @events = []
      @event_seq = 0
      @flaps = {}
      @log = log || StringIO.new
      build_lsdb
      build_neighbor(transport, debug)
      event :info, "topology loaded: #{counts_text}"
    end

    # ---- lifecycle

    def start
      synchronize do
        @neighbor.start
        @started_at = Time.now
        event :info, "neighbor started on #{settings.interface} (router id #{rid_s(settings.router_id)}, area #{rid_s(settings.area)})"
      end
      self
    end

    def stop
      @flaps.each_value(&:kill)
      @flaps.clear
      synchronize do
        @neighbor.stop
        event :info, 'neighbor stopped'
      end
      self
    end

    def running?
      @neighbor.running?
    end

    def synchronize(&block)
      @neighbor ? @neighbor.synchronize(&block) : @lock.synchronize(&block)
    end

    # ---- live changes

    def link(ref)
      find_link(ref)
    end

    def link_down(ref)
      synchronize do
        l = find_link(ref)
        next l unless l.up?
        l.down!
        reoriginate @ls_db.link_down(l.lsdb_link), "link #{l.name} down"
        l
      end
    end

    def link_up(ref)
      synchronize do
        l = find_link(ref)
        next l if l.up?
        l.up!
        reoriginate @ls_db.link_up(l.lsdb_link), "link #{l.name} up"
        l
      end
    end

    def toggle_link(ref)
      find_link(ref).up? ? link_down(ref) : link_up(ref)
    end

    # Takes the link down and up +count+ times, +interval+ seconds apart,
    # in the background. Returns immediately.
    def flap(ref, count: 3, interval: 5)
      l = find_link(ref)
      @flaps[l.id]&.kill
      event :info, "flapping #{l.name} #{count}x every #{interval}s"
      @flaps[l.id] = Thread.new do
        Thread.current.name = "flap-#{l.id}"
        count.times do
          link_down(l.id)
          sleep interval
          link_up(l.id)
          sleep interval
        end
        @flaps.delete(l.id)
      end
      l
    end

    # Re-originates every LSA the simulator owns (new sequence numbers).
    def refresh_all
      synchronize { reoriginate(@ls_db.all_proxied, 'refresh of all originated LSAs') }
    end

    # Flushes every LSA the simulator owns (MaxAge), e.g. before leaving.
    def flush_all
      synchronize do
        lsas = @ls_db.all_proxied
        lsas.each(&:maxage)
        @neighbor.flood(lsas) if @neighbor.full?
        event :lsdb, "flushed #{lsas.size} LSAs"
      end
    end

    def aging=(on)
      LsAge.aging(on ? :on : :off)
      event :info, "LSA aging #{on ? 'on' : 'off'}"
    end

    def aging?
      !!LsAge.aging?
    end

    # ---- views

    def events(since: 0)
      @lock.synchronize { @events.select { |e| e.seq > since } }
    end

    def lsdb_text(format = :junos, verbose: false)
      synchronize do
        case format.to_sym
        when :junos then verbose ? @ls_db.to_s_junos_verbose : @ls_db.to_s_junos
        when :ios then verbose ? @ls_db.to_s_ios_verbose : @ls_db.to_s_ios
        else @ls_db.to_s(verbose)
        end
      end
    end

    def lsa(type, ls_id, advr)
      synchronize { @ls_db.lookup(type.to_sym, ls_id, advr) }
    end

    # Plain data describing the whole simulation, for JSON and the UI.
    def snapshot
      synchronize do
        {
          version: OSPFv2::VERSION,
          running: running?,
          started_at: @started_at&.iso8601,
          aging: aging?,
          neighbor: @neighbor.to_hash,
          counts: lsdb_counts,
          topology: { counts: @topology.counts, link_prefix: @topology.lsdb[:link_prefix] },
          graph: graph,
          links: @links.map(&:to_h),
          event_seq: @event_seq
        }
      end
    end

    def lsdb_rows
      synchronize do
        @ls_db.all.sort_by { |l| [l.ls_type.to_i, l.advertising_router.to_i, lsa_id(l)] }.map do |l|
          {
            type: l.ls_type.to_sym, type_name: l.ls_type.to_junos, ls_id: IP.create(lsa_id(l)).to_s,
            advertising_router: l.advertising_router.to_ip, seq: format('0x%08x', l.sequence_number.to_I),
            age: l.ls_age.to_i, checksum: format('0x%04x', l.encode && l.send(:csum_to_i)),
            length: l.encode.bytesize, acked: l.ack?, originated: @ls_db.proxied?(l.advertising_router)
          }
        end
      end
    end

    def graph
      nodes = @topology.all_routers.map do |r|
        { id: r.name, router_id: rid_s(r.id), grid: r.grid, sim: r.name == Topology::SIM, abr: r.abr,
          asbr: r.asbr, networks: r.networks.size, summaries: r.summaries.size, externals: r.externals.size }
      end
      nodes << { id: 'dut', router_id: @neighbor.neighbor_router_id&.to_ip, dut: true, address: @neighbor.neighbor_ip }
      edges = @links.map { |l| { id: l.id, from: l.spec.from, to: l.spec.to, metric: l.spec.metric, up: l.up? } }
      edges << { id: 'dut', from: Topology::SIM, to: 'dut', up: @neighbor.full?, state: @neighbor.state }
      { nodes: nodes, edges: edges }
    end

    def settings
      @topology.settings
    end

    private

    def counts_text
      c = @topology.counts
      "#{c[:routers]} routers, #{c[:links]} links, #{c[:summaries]} summaries, #{c[:externals]} externals, #{@ls_db.size} LSAs"
    end

    def lsdb_counts
      @ls_db.all.group_by { |l| l.ls_type.to_sym }.transform_values(&:size).merge(total: @ls_db.size,
                                                                                  unacked: @ls_db.all_not_acked.size)
    end

    def lsa_id(l)
      l.is_opaque? ? (l.opaque_type.to_i << 24) + l.opaque_id.to_i : l.ls_id.to_i
    end

    def rid_s(id)
      IP.create(id).to_s
    end

    def event(kind, text)
      @lock.synchronize do
        @event_seq += 1
        @events << Event.new(seq: @event_seq, time: Time.now.strftime('%H:%M:%S'), kind: kind, text: text)
        @events.shift while @events.size > MAX_EVENTS
      end
    end

    def find_link(ref)
      l = case ref
          when LinkState then ref
          when Integer then @links.find { |x| x.id == ref }
          else
            s = ref.to_s
            @links.find { |x| x.id.to_s == s || x.name == s || "#{x.spec.to.to_s}--#{x.spec.from}" == s }
          end
      l or raise ArgumentError, "no such link: #{ref.inspect} (#{@links.first(3).map(&:name).join(', ')}...)"
    end

    def reoriginate(lsas, why)
      lsas = Array(lsas).compact.uniq
      return [] if lsas.empty?
      lsas.each { |l| l.force_refresh(nil) }
      @neighbor.flood(lsas) if @neighbor.full?
      event :lsdb, "#{why}: re-originated #{lsas.size} LSA#{'s' unless lsas.size == 1}"
      lsas
    end

    def build_lsdb
      LSDB::Link.reset
      LSDB::Link.base_ip_addr(@topology.lsdb[:link_prefix])
      @ls_db = LSDB::LinkStateDatabase.new(area_id: settings.area)
      @ls_db.ls_refresh_time = @topology.lsdb[:refresh_time]
      by_name = @topology.all_routers.to_h { |r| [r.name, r] }

      @sim_lsa = ensure_router_lsa(settings.router_id)
      @sim_lsa << interface_stub

      @links = @topology.links.each_with_index.map do |spec, i|
        a = by_name.fetch(spec.from)
        b = by_name.fetch(spec.to)
        lsdb_link = @ls_db.new_link(router_id: a.id, neighbor_id: b.id, metric: spec.metric)
        ls = LinkState.new(i + 1, spec, lsdb_link)
        @ls_db.link_down(lsdb_link) unless spec.up?
        ls
      end

      @topology.routers.each_value do |r|
        rlsa = ensure_router_lsa(r.id)
        rlsa.set_abr if r.abr
        rlsa.set_asbr if r.asbr
        r.networks.each do |n|
          @ls_db.add_link_to_stub_network(router_id: r.id, network: n.prefix, metric: n.metric)
        end
        r.summaries.each do |s|
          @ls_db << Summary.new(advertising_router: r.id, network: s.prefix, metric: s.metric)
        end
        r.asbr_summaries.each do |a|
          @ls_db << AsbrSummary.new(advertising_router: r.id, ls_id: a, metric: 1)
        end
        r.externals.each do |e|
          h = { advertising_router: r.id, network: e.prefix, metric: e.metric, type: e.type == 1 ? :e1 : :e2 }
          h[:tag] = e.tag if e.tag
          h[:forwarding_address] = e.forwarding_address if e.forwarding_address
          @ls_db << AsExternal.new(h)
        end
      end
      @ls_db.all.each(&:encode) # compute checksums once
    end

    def ensure_router_lsa(rid)
      @ls_db.find_router_lsa(rid) || begin
        @ls_db.advertised_routers << rid
        @ls_db << Router.new(advertising_router: rid, ls_id: rid, options: 0x22)
      end
    end

    def interface_stub
      net = settings.prefix
      { router_link_type: :stub_network, link_id: net.to_s, link_data: net.netmask, metric: settings.metric }
    end

    def build_neighbor(transport, debug)
      s = settings
      @neighbor = Neighbor.new(router_id: s.router_id, area_id: s.area, src_addr: s.interface,
                               hello_interval: s.hello_interval, dead_interval: s.dead_interval,
                               network_type: s.network_type, interface: s.device,
                               transport: transport, log: @log, debug: debug)
      @neighbor.ls_db = @ls_db
      @neighbor.on_state_change do |old, new, why|
        event :neighbor, "#{old} -> #{new} (#{why})"
        update_interface_link(new)
      end
    end

    # RFC 2328 12.4.1: describe the segment towards the DUT. A stub while
    # the adjacency is not up; once Full, a transit link to the DR on a
    # broadcast network, or a point-to-point link plus the subnet stub on
    # a point-to-point network. Without this the DUT has no link back to
    # the simulated area and installs none of its routes.
    def update_interface_link(state)
      before = @sim_lsa.links.map(&:encode).sort
      net = settings.prefix
      @sim_lsa.delete(:stub_network, net.to_s)
      @sim_lsa.links.delete_if { |l| [2].include?(l.router_link_type.to_i) }
      nbr_rid = @neighbor.neighbor_router_id
      @sim_lsa.links.delete_if { |l| l.router_link_type.to_i == 1 && nbr_rid && l.link_id.to_i == nbr_rid.to_i }
      if state == :full && settings.network_type == :p2p && nbr_rid
        @sim_lsa << { router_link_type: :point_to_point, link_id: nbr_rid.to_ip, link_data: settings.address, metric: settings.metric }
        @sim_lsa << interface_stub
      elsif state == :full && (dr = @neighbor.hello.designated_router_id.to_ip) != '0.0.0.0'
        @sim_lsa << { router_link_type: :transit_network, link_id: dr, link_data: settings.address, metric: settings.metric }
      else
        @sim_lsa << interface_stub
      end
      reoriginate(@sim_lsa, "interface link (#{state})") if @sim_lsa.links.map(&:encode).sort != before
    end
  end
end
