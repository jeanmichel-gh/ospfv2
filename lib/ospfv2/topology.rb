# frozen_string_literal: true

require 'yaml'
require 'ipaddr'
require_relative 'infra/ospf_common'

module OSPFv2
  # Declarative description of a simulated OSPF area.
  #
  # A Topology is plain data: the simulated router that talks to the
  # device under test, a set of routers with their prefixes, and the
  # point-to-point links between them. Simulator turns it into an LSDB.
  #
  # It can be loaded from YAML (see examples/*.yml), built from a Hash,
  # or written in Ruby:
  #
  #   topo = OSPFv2::Topology.build do
  #     simulator router_id: '1.1.1.1', interface: '192.168.1.10/24'
  #     grid columns: 3, rows: 3, metric: 10
  #     router 'edge', id: '10.0.0.1', asbr: true do
  #       externals '50.0.0.0/24', count: 100, metric: 20
  #     end
  #     link 'edge', 'r3c3', metric: 5
  #   end
  class Topology
    class Error < StandardError; end

    Prefix  = Struct.new(:prefix, :metric, keyword_init: true)
    External = Struct.new(:prefix, :metric, :type, :tag, :forwarding_address, keyword_init: true)

    Router = Struct.new(:name, :id, :abr, :asbr, :networks, :summaries, :asbr_summaries,
                        :externals, :grid, keyword_init: true) do
      def id_ip
        IP.create(id).to_s
      end

      def to_h
        h = { name: name, id: id_ip }
        h[:abr] = true if abr
        h[:asbr] = true if asbr
        h[:networks] = networks.map { |n| n.to_h.compact } unless networks.empty?
        h[:summaries] = summaries.map { |n| n.to_h.compact } unless summaries.empty?
        h[:asbr_summaries] = asbr_summaries.map { |i| IP.create(i).to_s } unless asbr_summaries.empty?
        h[:externals] = externals.map { |n| n.to_h.compact } unless externals.empty?
        h[:grid] = grid if grid
        h
      end
    end

    Link = Struct.new(:from, :to, :metric, :state, keyword_init: true) do
      def up?
        state != :down
      end

      def name
        "#{from}--#{to}"
      end
    end

    Settings = Struct.new(:router_id, :interface, :device, :area, :hello_interval, :dead_interval,
                          :network_type, :metric, keyword_init: true) do
      def address
        interface.split('/').first
      end

      def prefix
        IPAddr.new(interface)
      end
    end

    SIM = 'sim'

    attr_reader :settings, :routers, :links, :lsdb

    def self.load(path)
      data = YAML.safe_load(File.read(path), symbolize_names: true) || {}
      from_hash(data, source: path)
    rescue Psych::SyntaxError => e
      raise Error, "#{path}: #{e.message}"
    end

    def self.from_hash(hash, source: 'topology')
      new.tap { |t| t.send(:load_hash, hash, source) }
    end

    def self.build(&block)
      t = new
      Builder.new(t).instance_eval(&block)
      t.validate!
      t
    end

    def initialize
      @settings = Settings.new(router_id: IP.create('1.1.1.1').to_i, interface: '192.168.1.123/24', area: 0,
                               hello_interval: 10, network_type: :broadcast, metric: 10)
      @routers = {}
      @links = []
      @lsdb = { refresh_time: 2000, link_prefix: '13.0.0.0/30' }
      @attach = :auto
    end

    # All routers, the simulated one first.
    def all_routers
      [sim_router, *@routers.values]
    end

    def sim_router
      Router.new(name: SIM, id: settings.router_id, networks: [], summaries: [], asbr_summaries: [],
                 externals: [])
    end

    # Finds a router by name or by router id (dotted or integer).
    def router(name_or_id)
      key = name_or_id.to_s
      return @routers[key] if @routers.key?(key)
      rid = begin
        id_of(name_or_id)
      rescue Error
        nil
      end
      return sim_router if key == SIM || rid == settings.router_id
      rid && @routers.values.find { |r| r.id == rid }
    end

    def counts
      {
        routers: @routers.size + 1,
        links: @links.size,
        networks: all_routers.sum { |r| r.networks.size },
        summaries: all_routers.sum { |r| r.summaries.size },
        asbr_summaries: all_routers.sum { |r| r.asbr_summaries.size },
        externals: all_routers.sum { |r| r.externals.size }
      }
    end

    def to_h
      s = settings
      {
        simulator: {
          router_id: IP.create(s.router_id).to_s, interface: s.interface, device: s.device,
          area: IP.create(s.area).to_s, hello_interval: s.hello_interval, dead_interval: s.dead_interval,
          network_type: s.network_type.to_s, metric: s.metric
        }.compact,
        lsdb: @lsdb,
        routers: @routers.values.map(&:to_h),
        links: @links.map { |l| { from: l.from, to: l.to, metric: l.metric, state: (l.up? ? nil : 'down') }.compact }
      }
    end

    def to_yaml
      JSON.parse(JSON.generate(to_h)).to_yaml
    end

    # ---- mutation API (used by the loader, the builder and the console)

    def configure(opts)
      s = @settings
      opts.each do |k, v|
        case k.to_sym
        when :router_id      then s.router_id = id_of(v, 'simulator.router_id')
        when :interface      then s.interface = check_prefix(v, 'simulator.interface', host: true)
        when :device         then s.device = v.to_s
        when :area           then s.area = id_of(v, 'simulator.area')
        when :hello_interval then s.hello_interval = positive(v, 'simulator.hello_interval')
        when :dead_interval  then s.dead_interval = positive(v, 'simulator.dead_interval')
        when :metric         then s.metric = metric(v, 'simulator.metric')
        when :network_type
          s.network_type = { 'broadcast' => :broadcast, 'p2p' => :p2p, 'point_to_point' => :p2p }.fetch(v.to_s) do
            raise Error, "simulator.network_type: expected broadcast or p2p, got #{v.inspect}"
          end
        when :attach_to then @attach = v.to_s == 'none' ? :none : v.to_s
        else raise Error, "simulator: unknown key #{k}"
        end
      end
      self
    end

    def add_router(name: nil, id:, abr: false, asbr: false, networks: [], loopback: nil, loopbacks: [],
                   summaries: [], asbr_summaries: [], externals: [], grid: nil, where: 'router')
      rid = id_of(id, "#{where}.id")
      name = (name || IP.create(rid).to_s).to_s
      raise Error, "#{where}: name '#{SIM}' is reserved for the simulated router" if name == SIM
      raise Error, "#{where}: router id #{IP.create(rid)} is the simulator's router id" if rid == settings.router_id
      raise Error, "#{where}: duplicate router name #{name}" if @routers.key?(name)
      if (dup = @routers.values.find { |r| r.id == rid })
        raise Error, "#{where}: router id #{IP.create(rid)} already used by #{dup.name}"
      end

      nets = Array(networks).each_with_index.map { |n, i| prefix_entry(n, "#{where}.networks[#{i}]") }
      ([loopback] + Array(loopbacks)).compact.each_with_index do |lb, i|
        ip = lb.to_s.split('/').first
        nets << Prefix.new(prefix: check_prefix("#{ip}/32", "#{where}.loopback[#{i}]"), metric: 0)
      end
      sums = Array(summaries).each_with_index.flat_map { |s, i| expand(s, "#{where}.summaries[#{i}]") }
      exts = Array(externals).each_with_index.flat_map { |e, i| expand(e, "#{where}.externals[#{i}]", external: true) }
      asbrs = Array(asbr_summaries).each_with_index.map { |a, i| id_of(a, "#{where}.asbr_summaries[#{i}]") }

      @routers[name] = Router.new(name: name, id: rid, abr: !!abr || !sums.empty?, asbr: !!asbr || !exts.empty?,
                                  networks: nets, summaries: sums, asbr_summaries: asbrs, externals: exts,
                                  grid: grid)
    end

    def add_link(from, to, metric: nil, state: nil, where: 'link')
      a = router(from) or raise Error, "#{where}: unknown router #{from.inspect}"
      b = router(to) or raise Error, "#{where}: unknown router #{to.inspect}"
      raise Error, "#{where}: a link needs two different routers" if a.id == b.id
      st = state.nil? ? :up : state.to_s.to_sym
      raise Error, "#{where}: state must be up or down" unless %i[up down].include?(st)
      if @links.any? { |l| [l.from, l.to].sort == [a.name, b.name].sort }
        raise Error, "#{where}: duplicate link #{a.name} -- #{b.name}"
      end
      @links << Link.new(from: a.name, to: b.name, metric: metric.nil? ? settings.metric : metric(metric, "#{where}.metric"),
                         state: st)
      @links.last
    end

    # Adds a columns x rows grid named r<row>c<col>. Router ids are
    # base + (row << 16) + col, so r2c3 is 0.2.0.3 with the default base.
    def add_grid(columns:, rows:, base_router_id: 0, metric: nil, where: 'grid')
      cols = positive(columns, "#{where}.columns")
      rws = positive(rows, "#{where}.rows")
      raise Error, "#{where}: at most 255 rows and 65535 columns" if rws > 255 || cols > 0xffff
      base = id_of(base_router_id, "#{where}.base_router_id")
      1.upto(rws) do |r|
        1.upto(cols) do |c|
          add_router(name: "r#{r}c#{c}", id: base + (r << 16) + c, grid: [r, c], where: where)
        end
      end
      1.upto(rws) do |r|
        1.upto(cols) do |c|
          add_link("r#{r}c#{c - 1}", "r#{r}c#{c}", metric: metric, where: where) if c > 1
          add_link("r#{r - 1}c#{c}", "r#{r}c#{c}", metric: metric, where: where) if r > 1
        end
      end
      @attach = 'r1c1' if @attach == :auto
      self
    end

    def configure_lsdb(opts)
      opts.each do |k, v|
        case k.to_sym
        when :refresh_time then @lsdb[:refresh_time] = positive(v, 'lsdb.refresh_time')
        when :link_prefix  then @lsdb[:link_prefix] = check_prefix(v, 'lsdb.link_prefix')
        else raise Error, "lsdb: unknown key #{k}"
        end
      end
    end

    # Connects the simulated router to the rest of the topology: to the
    # router named by simulator.attach_to, or to r1c1 for a grid, or to
    # the first router. Skipped when a link already touches the simulator.
    def attach!
      return if @attach == :none || @routers.empty?
      return if @links.any? { |l| l.from == SIM || l.to == SIM }
      target = @attach == :auto ? @routers.keys.first : @attach
      add_link(SIM, target, where: 'simulator.attach_to')
    end

    def validate!
      attach!
      self
    end

    private

    def load_hash(h, source)
      h = h.transform_keys(&:to_sym)
      unknown = h.keys - %i[simulator lsdb grid routers links]
      raise Error, "#{source}: unknown section(s) #{unknown.join(', ')}" unless unknown.empty?
      configure(h[:simulator] || {})
      configure_lsdb(h[:lsdb] || {})
      if (g = h[:grid])
        g = g.transform_keys(&:to_sym)
        attach = g.delete(:attach_to)
        unknown = g.keys - %i[columns rows base_router_id metric]
        raise Error, "grid: unknown key(s) #{unknown.join(', ')}" unless unknown.empty?
        add_grid(**g)
        @attach = attach.to_s == 'none' ? :none : attach.to_s if attach
      end
      Array(h[:routers]).each_with_index do |r, i|
        raise Error, "routers[#{i}]: expected a mapping" unless r.is_a?(Hash)
        r = r.transform_keys(&:to_sym)
        allowed = %i[name id abr asbr networks loopback loopbacks summaries asbr_summaries externals]
        unknown = r.keys - allowed
        raise Error, "routers[#{i}]: unknown key(s) #{unknown.join(', ')}" unless unknown.empty?
        raise Error, "routers[#{i}]: id is required" unless r[:id]
        add_router(**r, where: "routers[#{i}]")
      end
      Array(h[:links]).each_with_index do |l, i|
        where = "links[#{i}]"
        case l
        when Array
          from, to, opts = l
          opts = (opts || {}).transform_keys(&:to_sym)
          add_link(from, to, metric: opts[:metric], state: opts[:state], where: where)
        when Hash
          l = l.transform_keys(&:to_sym)
          unknown = l.keys - %i[from to metric state]
          raise Error, "#{where}: unknown key(s) #{unknown.join(', ')}" unless unknown.empty?
          add_link(l[:from], l[:to], metric: l[:metric], state: l[:state], where: where)
        else
          raise Error, "#{where}: expected [from, to] or {from:, to:}"
        end
      end
      validate!
    rescue ArgumentError => e
      raise Error, "#{source}: #{e.message}"
    end

    def id_of(v, where = 'id')
      case v
      when Integer
        raise Error, "#{where}: #{v} is out of range" unless (0..0xffffffff).cover?(v)
        v
      when String
        return IPAddr.new(v).to_i if v.match?(/\A\d+\.\d+\.\d+\.\d+\z/)
        return Integer(v) if v.match?(/\A\d+\z/)
        raise Error, "#{where}: #{v.inspect} is not a router id"
      else
        raise Error, "#{where}: #{v.inspect} is not a router id"
      end
    rescue IPAddr::InvalidAddressError
      raise Error, "#{where}: #{v.inspect} is not a router id"
    end

    def check_prefix(v, where, host: false)
      s = v.to_s
      raise Error, "#{where}: #{s.inspect} needs a prefix length, e.g. 10.0.0.1/24" unless s.include?('/')
      ip = IPAddr.new(s)
      raise Error, "#{where}: only IPv4 is supported" unless ip.ipv4?
      host ? s : "#{ip}/#{ip.prefix}"
    rescue IPAddr::InvalidAddressError, IPAddr::InvalidPrefixError
      raise Error, "#{where}: #{s.inspect} is not a valid prefix"
    end

    def positive(v, where)
      i = Integer(v)
      raise Error, "#{where}: must be > 0" unless i.positive?
      i
    rescue ArgumentError, TypeError
      raise Error, "#{where}: #{v.inspect} is not a number"
    end

    def metric(v, where)
      i = Integer(v)
      raise Error, "#{where}: metric must be 0..65535" unless (0..0xffff).cover?(i)
      i
    rescue ArgumentError, TypeError
      raise Error, "#{where}: #{v.inspect} is not a number"
    end

    def prefix_entry(n, where)
      n = { prefix: n } unless n.is_a?(Hash)
      n = n.transform_keys(&:to_sym)
      Prefix.new(prefix: check_prefix(n[:prefix], where), metric: n[:metric].nil? ? 1 : metric(n[:metric], where))
    end

    # "30.0.0.0/24" or {prefix:, count:, metric:, ...} => one entry per network
    def expand(entry, where, external: false)
      entry = { prefix: entry } unless entry.is_a?(Hash)
      e = entry.transform_keys(&:to_sym)
      allowed = %i[prefix count metric] + (external ? %i[type tag forwarding_address] : [])
      unknown = e.keys - allowed
      raise Error, "#{where}: unknown key(s) #{unknown.join(', ')}" unless unknown.empty?
      base = IPAddr.new(check_prefix(e[:prefix], where))
      count = e[:count].nil? ? 1 : positive(e[:count], "#{where}.count")
      m = e[:metric].nil? ? (external ? 20 : 10) : metric(e[:metric], "#{where}.metric")
      Array.new(count) do |i|
        pfx = IP.nth_network(base, i)
        if external
          type = (e[:type] || 2).to_i
          raise Error, "#{where}.type: must be 1 or 2" unless [1, 2].include?(type)
          External.new(prefix: pfx, metric: m, type: type, tag: e[:tag]&.to_i,
                       forwarding_address: e[:forwarding_address])
        else
          Prefix.new(prefix: pfx, metric: m)
        end
      end
    end

    # Ruby DSL used by Topology.build.
    class Builder
      def initialize(topology)
        @t = topology
      end

      def simulator(**opts) = @t.configure(opts)
      def lsdb(**opts) = @t.configure_lsdb(opts)
      def grid(**opts) = @t.add_grid(**opts)
      def link(from, to, **opts) = @t.add_link(from, to, **opts)

      def router(name = nil, id:, **opts, &block)
        if block
          rb = RouterBuilder.new
          rb.instance_eval(&block)
          opts = rb.opts.merge(opts) { |_, a, b| Array(a) + Array(b) }
        end
        @t.add_router(name: name, id: id, **opts)
      end
    end

    class RouterBuilder
      attr_reader :opts

      def initialize
        @opts = Hash.new { |h, k| h[k] = [] }
      end

      def network(prefix, metric: 1) = (@opts[:networks] << { prefix: prefix, metric: metric })
      def loopback(addr) = (@opts[:loopbacks] << addr)
      def summaries(prefix, **o) = (@opts[:summaries] << { prefix: prefix, **o })
      def externals(prefix, **o) = (@opts[:externals] << { prefix: prefix, **o })
      def asbr_summary(id) = (@opts[:asbr_summaries] << id)
      alias summary summaries
      alias external externals
    end
  end
end

require 'json'
