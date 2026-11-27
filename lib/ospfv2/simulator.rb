# frozen_string_literal: true

require 'monitor'
require 'ipaddr'
require 'time'
require 'stringio'
require_relative '../ospfv2'
require_relative 'topology'
require_relative 'core/lsa'
require_relative 'fault'

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
    # time: the clock time, HH:MM:SS, as it always was. at: the same
    # moment in full, UTC with milliseconds. data: what text says, as
    # fields; for an LSA action, lsas: [{type, id, advr, seq}].
    Event = Struct.new(:seq, :time, :at, :kind, :text, :data, keyword_init: true)

    # No such LSA, router or prefix: the web API answers 404.
    class NotFound < StandardError; end

    LSA_TYPES = %w[router network summary asbr_summary as_external].freeze

    # A topology link and the LSDB link that implements it.
    class LinkState
      attr_reader :id, :spec, :lsdb_link

      def initialize(id, spec, lsdb_link)
        @id = id
        @spec = spec
        @lsdb_link = lsdb_link
        @up = spec.up?
        @metric = spec.metric
      end

      attr_accessor :metric

      def name = spec.name
      def up? = @up
      def up! = (@up = true)
      def down! = (@up = false)

      def to_h
        { id: id, name: name, from: spec.from, to: spec.to, metric: @metric, up: @up,
          network: lsdb_link.network_to_s }
      end
    end

    MAX_EVENTS = 500

    attr_reader :topology, :ls_db, :neighbor, :links, :started_at

    # transport: optional Transport (default raw socket on the interface)
    # log:       IO or file name for protocol traces (default: discard)
    # min_ls_interval: seconds between two instances of one LSA, RFC 2328
    #            12.4. MinLSInterval, 5 s; tests pass less so they do not
    #            sleep. A topology file cannot change it.
    def initialize(topology, transport: nil, log: nil, debug: false, min_ls_interval: OSPFv2::MinLSInterval)
      @topology = topology
      @lock = Monitor.new
      @event_cond = @lock.new_cond
      @events = []
      @event_seq = 0
      @flaps = {}
      @flushed_seq = {}
      @flushed_lsas = {} # key => an LSA flushed on its own, to bring back
      @min_ls_interval = min_ls_interval.to_f
      @last_sent = {}    # key => monotonic time its last instance went out
      @held = {}         # key => { due:, floor:, why: }, an instance MinLSInterval holds
      @faults = {}       # [type, ls_id, advr] => the last fault LSA sent (OSPFv2::Fault)
      @releaser = nil    # the thread that sends held instances when due
      @log = log || StringIO.new
      build_lsdb
      build_neighbor(transport, debug)
      event :info, "topology loaded: #{counts_text}"
    end

    # ---- lifecycle

    def start
      synchronize do
        restore if flushed?
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
        settle_held
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

    # Sets the link's metric, both ways. An up link re-originates its two
    # router LSAs; a down one comes back up with it.
    def set_metric(ref, metric)
      metric = Integer(metric, exception: false) || raise(ArgumentError, "metric #{metric.inspect}: a number")
      raise ArgumentError, "metric #{metric}: from 1 to 65535" unless (1..65_535).cover?(metric)
      synchronize do
        l = find_link(ref)
        next l if l.metric == metric
        was = l.metric
        l.metric = metric
        l.lsdb_link.metric = metric
        if l.up?
          reoriginate relink(l), "link #{l.name} metric #{was} to #{metric}"
        else
          event :info, "link #{l.name} metric #{was} to #{metric}, used when it comes up"
        end
        l
      end
    end

    # The link's two router LSA entries again, with its current metric.
    def relink(l)
      (@ls_db.link_down(l.lsdb_link) + @ls_db.link_up(l.lsdb_link)).uniq
    end
    private :relink

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
    # After a flush, rebuilds them from the topology first.
    # A flushed LSA, whole or one of them, is rebuilt from the topology
    # first, so refresh_all brings everything back.
    def refresh_all
      synchronize do
        next restore if flushed?
        @flushed_lsas.each_value { reinsert(_1) }
        @flushed_lsas.clear
        reoriginate(@ls_db.all_proxied, 'refresh of all originated LSAs')
      end
    end

    # Flushes every LSA the simulator owns (MaxAge). The router acks and
    # deletes them, and so do we. Refresh, or a neighbor restart, brings
    # them back from the topology.
    def flush_all
      synchronize do
        @held.clear
        lsas = @ls_db.all_proxied
        lsas.each { |l| @flushed_seq[l.key] = l.sequence_number.to_I }
        lsas.each(&:maxage)
        sent(lsas)
        @neighbor.flood(lsas) if @neighbor.adjacent?
        event :lsdb, "flushed #{lsas.size} LSAs. Refresh LSAs or restart the neighbor to originate them again",
              lsas_data(lsas).merge(flushed: true)
        lsas
      end
    end

    def flushed?
      !@flushed_seq.empty?
    end

    # Rebuilds the database from the topology after a flush. Link states
    # set since the start carry over, and every LSA gets a sequence number
    # above the flushed copy so the router takes it as newer.
    def restore
      synchronize do
        down = @links.reject(&:up?).map(&:id)
        metrics = @links.to_h { [_1.id, _1.metric] }
        build_lsdb
        @neighbor.ls_db = @ls_db
        @links.each do |l|
          if l.metric != metrics[l.id]
            l.metric = l.lsdb_link.metric = metrics[l.id]
            relink(l)
          end
          if down.include?(l.id)
            l.down! if l.up?
            @ls_db.link_down(l.lsdb_link)
          elsif !l.up?
            l.up!
            @ls_db.link_up(l.lsdb_link)
          end
        end
        floors = @flushed_lsas.transform_values { _1.sequence_number.to_I }.merge(@flushed_seq)
        @flushed_seq.clear
        @flushed_lsas.clear
        update_interface_link(@neighbor.state, flood: false)
        reoriginate(@ls_db.all_proxied, 'restore from the topology', floors: floors)
      end
    end

    def aging=(on)
      LsAge.aging(on ? :on : :off)
      event :info, "LSA aging #{on ? 'on' : 'off'}"
    end

    def aging?
      !!LsAge.aging?
    end

    # Seconds between two instances of one LSA, from 0 to 5. 5 is RFC
    # 2328's MinLSInterval (12.4, Appendix B) and the default; 0 sends
    # every change at once, as a test that wants to push a router may
    # ask. A held instance is due again from the new value, so lowering
    # it sends what is due now.
    def min_ls_interval=(seconds)
      v = Float(seconds, exception: false)
      raise ArgumentError, "min_ls_interval #{seconds.inspect}: seconds from 0 to #{OSPFv2::MinLSInterval}" unless v && v.between?(0, OSPFv2::MinLSInterval)
      synchronize do
        @min_ls_interval = v
        @held.each { |key, h| h[:due] = (@last_sent[key] || 0) + v }
        release(mono)
        start_releaser unless @held.empty?
        event :info, "MinLSInterval #{v.zero? ? 'off' : "#{v} s"}"
      end
    end

    def min_ls_interval = @min_ls_interval

    # ---- faults (OSPFv2::Fault, docs/design/sr-ospf.md step 0)

    # A fault LSA as the neighbor floods it: its own octets, never
    # re-encoded, since an entry is wrong on purpose.
    FaultLsa = Struct.new(:lsa) do
      def encode = lsa.bytes
      def to_s = "fault LSA type #{lsa.type} #{Core::Addr.to_s(lsa.ls_id)} from #{Core::Addr.to_s(lsa.advr)}"
    end

    # Floods the catalog's entry +name+, from +router+ (the simulator's
    # router ID when nil). It is not in the simulator's database: it is
    # sent once, a newer instance each time, and fault_clear flushes it.
    def fault(name, router: nil)
      entry = Fault.entry(name)
      synchronize do
        advr = router ? Core::Addr.to_s(Core::Addr.to_i(router)) : rid_s(settings.router_id)
        type, ls_id, = entry[:build].call(Fault.context(router_id: advr))
        last = @faults[[type, ls_id, advr]]
        lsa = Fault.lsa(name, router_id: advr, seq: last ? last.seq + 1 : 0x8000_0001)
        @faults[[type, ls_id, advr]] = lsa
        sent = @neighbor&.adjacent? ? true : false
        @neighbor.flood([FaultLsa.new(lsa)]) if sent
        row = fault_row(name, lsa).merge(finding: entry[:finding], expect: entry[:expect], rfc: entry[:rfc], sent: sent)
        event :lsdb, "fault #{name}: #{entry[:description]}#{sent ? '' : ', not sent: no adjacency'}", row
        row
      end
    end

    # Flushes every fault LSA sent (RFC 2328 14.1: MaxAge).
    def fault_clear
      synchronize do
        lsas = @faults.values.map { _1.with_age(OSPFv2::MaxAge) }
        @faults.clear
        @neighbor.flood(lsas.map { FaultLsa.new(_1) }) if @neighbor&.adjacent? && !lsas.empty?
        event :lsdb, "faults cleared: #{plural(lsas.size, 'LSA')} flushed", cleared: lsas.size
        { cleared: lsas.size }
      end
    end

    # The catalog, and the fault LSAs sent and not cleared.
    def faults
      synchronize do
        { catalog: Fault.catalog.map { _1.except(:build) },
          sent: @faults.map { |_, l| fault_row(nil, l) } }
      end
    end

    def fault_row(name, l)
      { case: name, type: l.type, id: Core::Addr.to_s(l.ls_id), advr: Core::Addr.to_s(l.advr),
        seq: format('0x%08x', l.seq & 0xffff_ffff), hex: l.bytes.unpack1('H*') }.compact
    end

    # ---- one LSA, and the topology's routes (docs/design/sim-lsa-actions.md)

    # A new instance of one LSA the simulator originates. One flushed on
    # its own comes back, above its flushed sequence number, with the
    # links it has now.
    def lsa_refresh(type, ls_id, advr)
      synchronize do
        key = lsa_key(type, ls_id, advr)
        if (l = @flushed_lsas[key])
          bring_back(l)
          next lsa_row(l)
        end
        l = own_lsa(key)
        reoriginate l, "refresh of #{describe(l)}"
        lsa_row(l)
      end
    end

    # Flushes one LSA the simulator originates (RFC 2328 14.1: MaxAge,
    # the same sequence number). Its own router LSA, which ties the area
    # to the router under test, is refused: stop the neighbor instead.
    def lsa_flush(type, ls_id, advr)
      synchronize do
        key = lsa_key(type, ls_id, advr)
        next lsa_row(@flushed_lsas[key]) if @flushed_lsas.key?(key)
        l = own_lsa(key)
        if l.equal?(@sim_lsa)
          raise PermissionError, "#{describe(l)} links the area to the router under test; stop the neighbor instead"
        end
        flush_one(l, "flush of #{describe(l)}")
        lsa_row(l)
      end
    end

    # Withdraws one of the topology's externals or summaries, by premature
    # aging (RFC 2328 14.1). +router+ is its name in the topology.
    def routes_withdraw(router, prefix)
      synchronize do
        kind, key = route_key(router, prefix)
        row = if @flushed_lsas.key?(key)
                lsa_row(@flushed_lsas[key]).merge(already: true)
              else
                l = @ls_db.lookup(key.dup) or raise NotFound, "#{kind} #{prefix} of #{router} is not in the database"
                flush_one(l, "withdraw of #{kind} #{prefix} from #{router}")
                lsa_row(l)
              end
        { kind: kind, router: router, prefix: prefix }.merge(row)
      end
    end

    # Advertises again one the topology's externals or summaries that was
    # withdrawn. One already advertised is left alone and says so.
    def routes_advertise(router, prefix)
      synchronize do
        kind, key = route_key(router, prefix)
        row = if (l = @flushed_lsas[key])
                bring_back(l)
                lsa_row(l)
              else
                l = @ls_db.lookup(key.dup) or raise NotFound, "#{kind} #{prefix} of #{router} is not in the database"
                lsa_row(l).merge(already: true)
              end
        { kind: kind, router: router, prefix: prefix }.merge(row)
      end
    end

    # ---- views

    def events(since: 0)
      @lock.synchronize { @events.select { |e| e.seq > since } }
    end

    # The events after +since+, waiting up to +timeout+ seconds for one
    # when there is none yet. For the event stream.
    def wait_events(since:, timeout:)
      @lock.synchronize do
        @event_cond.wait(timeout) if @events.empty? || @events.last.seq <= since
        @events.select { |e| e.seq > since }
      end
    end

    def event_seq = @lock.synchronize { @event_seq }

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
          flushed: flushed?,
          min_ls_interval: @min_ls_interval,
          neighbor: @neighbor.to_hash,
          neighbors: @neighbor.neighbors,
          counts: lsdb_counts,
          topology: { counts: @topology.counts, link_prefix: @topology.lsdb[:link_prefix] },
          graph: graph,
          links: @links.map(&:to_h),
          event_seq: @event_seq
        }
      end
    end

    # The LSAs it holds, one row each. +detail+ adds each body as plain
    # data, the shape ospfd's show.database gives (Core::Lsa#detail).
    def lsdb_rows(detail: false)
      synchronize do
        @ls_db.all.sort_by { |l| [l.ls_type.to_i, l.advertising_router.to_i, lsa_id(l)] }.map do |l|
          lsa_row(l, detail: detail)
        end
      end
    end

    # One LSA as lsdb_rows gives it. deferred_ms: MinLSInterval holds its
    # next instance that long. flushed: flushed on its own, to come back.
    def lsa_row(l, detail: false)
      row = {
        type: l.ls_type.to_sym, type_name: l.ls_type.to_junos, ls_id: IP.create(lsa_id(l)).to_s,
        advertising_router: l.advertising_router.to_ip, seq: format('0x%08x', l.sequence_number.to_I),
        age: l.ls_age.to_i, checksum: format('0x%04x', l.encode && l.send(:csum_to_i)),
        length: l.encode.bytesize, acked: l.ack?, originated: @ls_db.proxied?(l.advertising_router)
      }
      (ms = deferred_ms(l.key)) and row[:deferred_ms] = ms
      row[:flushed] = true if @flushed_lsas.key?(l.key)
      row[:detail] = lsa_detail(l) if detail
      row
    end

    def lsa_detail(l)
      Core::Lsa.parse(l.encode.b).detail
    rescue Core::Lsa::Error => e
      { error: e.message }
    end

    def graph
      nodes = @topology.all_routers.map do |r|
        { id: r.name, router_id: rid_s(r.id), grid: r.grid, sim: r.name == Topology::SIM, abr: r.abr,
          asbr: r.asbr, networks: r.networks.size, summaries: r.summaries.size, externals: r.externals.size }
      end
      nodes << { id: 'dut', router_id: @neighbor.neighbor_router_id&.to_ip, dut: true, address: @neighbor.neighbor_ip }
      edges = @links.map { |l| { id: l.id, from: l.spec.from, to: l.spec.to, metric: l.metric, up: l.up? } }
      edges << { id: 'dut', from: Topology::SIM, to: 'dut', up: @neighbor.full?, state: @neighbor.state }
      if (b = @neighbor.bdr_adjacency)
        nodes << { id: 'dut-bdr', router_id: b.neighbor_router_id&.to_ip, dut: true, address: b.neighbor_ip }
        edges << { id: 'dut-bdr', from: Topology::SIM, to: 'dut-bdr', up: b.full?, state: b.state }
      end
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
                                                                                  unacked: @ls_db.all_not_acked.size,
                                                                                  deferred: @held.size)
    end

    def lsa_id(l)
      l.is_opaque? ? (l.opaque_type.to_i << 24) + l.opaque_id.to_i : l.ls_id.to_i
    end

    def rid_s(id)
      IP.create(id).to_s
    end

    def event(kind, text, data = {})
      now = Time.now
      @lock.synchronize do
        @event_seq += 1
        @events << Event.new(seq: @event_seq, time: now.strftime('%H:%M:%S'), at: now.utc.iso8601(3),
                             kind: kind, text: text, data: data)
        @events.shift while @events.size > MAX_EVENTS
        @event_cond.broadcast
      end
    end

    # The LSAs of an event's data: what the console needs to follow one
    # instance from the simulator to each router.
    def lsas_data(lsas)
      { lsas: lsas.map do |l|
        { type: l.ls_type.to_sym, id: IP.create(lsa_id(l)).to_s, advr: l.advertising_router.to_ip,
          seq: format('0x%08x', l.sequence_number.to_I) }
      end }
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

    # Sends a new instance of each of +lsas+, at once or, inside
    # MinLSInterval of its last one, when that runs out (RFC 2328 12.4).
    # Their contents have changed already; a held LSA goes out once, with
    # what it holds then, however many changes joined it. +floors+: key =>
    # a sequence number the new instance must pass (a flushed copy's).
    def reoriginate(lsas, why, floors: {})
      lsas = Array(lsas).compact.uniq.reject { @flushed_lsas.key?(_1.key) }
      return [] if lsas.empty?
      now = mono
      ready, held = lsas.partition { |l| !@held.key?(l.key) && wait_for(l.key, now) <= 0 }
      unless ready.empty?
        ready.each { |l| l.force_refresh(floors[l.key]) }
        sent(ready, now)
        @neighbor.flood(ready) if @neighbor.adjacent?
        event :lsdb, "#{why}: re-originated #{plural(ready.size, 'LSA')}", lsas_data(ready)
      end
      unless held.empty?
        held.each { |l| hold(l.key, floors[l.key], why, now) }
        wait = held.map { |l| @held[l.key][:due] - now }.max
        event :lsdb, "#{why}: #{plural(held.size, 'LSA')} held by MinLSInterval, out in #{(wait * 1000).round} ms",
              lsas_data(held).merge(deferred_ms: (wait * 1000).round)
      end
      lsas
    end

    def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def plural(n, word) = "#{n} #{word}#{'s' unless n == 1}"

    # Seconds until a new instance of +key+ may go out; 0 or less: now.
    def wait_for(key, now = mono)
      (t = @last_sent[key]) ? t + @min_ls_interval - now : 0
    end

    def sent(lsas, now = mono)
      lsas.each { |l| @last_sent[l.key] = now }
    end

    # Milliseconds until a held instance of +key+ goes out, or nil.
    def deferred_ms(key)
      (h = @held[key]) ? [((h[:due] - mono) * 1000).round, 0].max : nil
    end

    def hold(key, floor, why, now)
      h = (@held[key] ||= { due: now + wait_for(key, now), floor: nil, why: why })
      h[:floor] = [h[:floor], floor].compact.max
      start_releaser
    end

    # One thread sends every held instance when it is due, and ends when
    # none is left. Both it and hold run under the lock, so a hold cannot
    # slip between its last look and its end.
    def start_releaser
      if @releaser&.alive?
        @releaser.wakeup rescue ThreadError
        return
      end
      @releaser = Thread.new do
        Thread.current.name = 'min-ls-interval'
        loop do
          due = synchronize do
            next(@releaser = nil) if @held.empty?
            @held.values.map { _1[:due] }.min
          end
          break unless due
          wait = due - mono
          sleep(wait) if wait.positive?
          synchronize { release(mono) }
        end
      end
    end

    # Sends the held instances that are due, in one flood and one event.
    def release(now)
      due = @held.select { |_, h| h[:due] <= now }
      return if due.empty?
      due.each_key { @held.delete(_1) }
      lsas = due.filter_map do |key, h|
        l = @ls_db.lookup(key.dup)
        next if l.nil? || @flushed_lsas.key?(key) # flushed again while it waited
        l.force_refresh(h[:floor])
      end
      return if lsas.empty?
      sent(lsas, now)
      @neighbor.flood(lsas) if @neighbor.adjacent?
      whys = due.values.map { _1[:why] }.uniq
      event :lsdb, "#{whys.join('; ')}: re-originated #{plural(lsas.size, 'LSA')} after MinLSInterval", lsas_data(lsas)
    end

    def lsa_key(type, ls_id, advr)
      t = type.to_s
      raise ArgumentError, "type #{t.inspect}: one of #{LSA_TYPES.join(', ')}" unless LSA_TYPES.include?(t)
      raise ArgumentError, 'id and advr are required' if ls_id.to_s.empty? || advr.to_s.empty?
      [LsType.to_i(t.to_sym), IPAddr.new(ls_id.to_s).to_i, IPAddr.new(advr.to_s).to_i]
    rescue IPAddr::InvalidAddressError => e
      raise ArgumentError, e.message
    end

    # An LSA the simulator originates (RFC 2328 14.1: it may age only its own).
    def own_lsa(key)
      l = @ls_db.lookup(key.dup) or raise NotFound, 'no such LSA'
      unless @ls_db.proxied?(l.advertising_router)
        raise PermissionError, "#{describe(l)} is not originated by the simulator (RFC 2328 14.1)"
      end
      l
    end

    def describe(l)
      "#{l.ls_type.to_sym} #{IP.create(lsa_id(l))} from #{l.advertising_router.to_ip}"
    end

    # [kind, key] of a topology router's external or summary.
    def route_key(router, prefix)
      r = @topology.all_routers.find { _1.name == router.to_s } or raise NotFound, "no router #{router.inspect}"
      want = IPAddr.new(prefix.to_s)
      same = ->(p) { a = IPAddr.new(p.prefix.to_s); a.to_s == want.to_s && a.prefix == want.prefix }
      kind = if Array(r.externals).any?(&same) then :as_external
             elsif Array(r.summaries).any?(&same) then :summary
             end
      unless kind
        have = (Array(r.externals) + Array(r.summaries)).map(&:prefix).first(6)
        raise NotFound, "#{router} has no external or summary #{prefix} (#{have.join(', ')}#{' ...' if have.size == 6})"
      end
      [kind, [LsType.to_i(kind), want.to_i, IPAddr.new(IP.create(r.id).to_s).to_i]]
    rescue IPAddr::InvalidAddressError => e
      raise ArgumentError, e.message
    end

    # Premature aging of one LSA (RFC 2328 14.1). A flush is an instance
    # too: the next one waits MinLSInterval.
    def flush_one(l, why)
      @held.delete(l.key)
      @flushed_lsas[l.key] = l
      l.maxage
      sent([l])
      @neighbor.flood([l]) if @neighbor.adjacent?
      event :lsdb, "#{why}: flushed at MaxAge, sequence #{format('0x%08x', l.sequence_number.to_I)}",
            lsas_data([l]).merge(flushed: true)
    end

    # A flushed LSA back in the database; a router LSA gets the links it
    # has now, since link changes skip a router LSA that is not there.
    def reinsert(l)
      @ls_db << l
      return unless l.ls_type.to_i == 1
      rid = l.advertising_router.to_i
      @links.each do |ln|
        ends = [ln.lsdb_link.router_id.to_i, ln.lsdb_link.neighbor_id.to_i]
        next unless ends.include?(rid)
        ln.up? ? relink(ln) : @ls_db.link_down(ln.lsdb_link)
      end
    end

    # Brings back one LSA flushed on its own, above its flushed sequence
    # number (its MaxAge copy kept it).
    def bring_back(l)
      @flushed_lsas.delete(l.key)
      reinsert(l)
      reoriginate l, "#{describe(l)} back"
    end

    # On a stop: a held instance takes its new sequence number now, with
    # no flood, so the database never holds new contents under an old
    # number while nobody is listening.
    def settle_held
      @held.each do |key, h|
        l = @ls_db.lookup(key.dup)
        l.force_refresh(h[:floor]) if l && !@flushed_lsas.key?(key)
      end
      @held.clear
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
      # @neighbor is the segment (an Interface); its state is the adjacency
      # with the DR's. Events name each adjacency's neighbor.
      @neighbor.on_adjacency_change do |nbr, old, new, why|
        event :neighbor, "#{nbr.neighbor_router_id&.to_ip || nbr.neighbor_ip}: #{old} -> #{new} (#{why})"
      end
      @neighbor.on_state_change { |_old, new, _why| update_interface_link(new) }
    end

    # RFC 2328 12.4.1: describe the segment towards the DUT. A stub while
    # the adjacency is not up; once Full, a transit link to the DR on a
    # broadcast network, or a point-to-point link plus the subnet stub on
    # a point-to-point network. Without this the DUT has no link back to
    # the simulated area and installs none of its routes.
    def update_interface_link(state, flood: true)
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
      return unless flood
      reoriginate(@sim_lsa, "interface link (#{state})") if @sim_lsa.links.map(&:encode).sort != before
    end
  end
end
