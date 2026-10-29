# frozen_string_literal: true

require 'optparse'
require 'json'
require 'fileutils'
require_relative 'simulator'
require_relative 'console'
require_relative 'infra/parse_options'

module OSPFv2
  # bin/ospfv2
  #
  #   ospfv2 run TOPOLOGY [--web PORT] [--console irb|none] [overrides]
  #   ospfv2 demo [TOPOLOGY] [--web PORT]      no router, no root needed
  #   ospfv2 show TOPOLOGY [--format junos|ios|plain|json] [--verbose]
  #   ospfv2 export TOPOLOGY --format dot|json|yaml
  #   ospfv2 check TOPOLOGY
  #   ospfv2 init [--grid 3x3] [--interface 10.0.0.2/24]
  #   ospfv2 lab new DIR [--no-git]
  #   ospfv2 -i 192.168.1.10/24 -g 3x3 ...       original flags, still work
  class CLI
    COMMANDS = %w[run demo show export check init lab capture version help].freeze

    def self.start(argv = ARGV, out: $stdout, err: $stderr)
      new(out: out, err: err).run(argv.dup)
    end

    def initialize(out: $stdout, err: $stderr)
      @out = out
      @err = err
    end

    def run(argv)
      cmd = argv.first
      if cmd.nil?
        @out.puts usage
        return 0
      end
      return legacy(argv) if cmd.start_with?('-') && !%w[-h --help -v --version].include?(cmd)
      cmd = argv.shift
      case cmd
      when 'run'     then cmd_run(argv)
      when 'demo'    then cmd_demo(argv)
      when 'show'    then cmd_show(argv)
      when 'export'  then cmd_export(argv)
      when 'check'   then cmd_check(argv)
      when 'init'    then cmd_init(argv)
      when 'lab'     then cmd_lab(argv)
      when 'capture' then cmd_capture(argv)
      when 'version', '-v', '--version' then @out.puts("ospfv2 #{VERSION}") || 0
      when 'help', '-h', '--help' then @out.puts(usage) || 0
      else
        @err.puts "ospfv2: unknown command '#{cmd}'\n\n#{usage}"
        2
      end
    rescue Topology::Error, OptionParser::ParseError, ArgumentError => e
      @err.puts "ospfv2: #{e.message}"
      2
    rescue PermissionError => e
      @err.puts "ospfv2: #{e.message}"
      77
    end

    def usage
      <<~TXT
        ospfv2 #{VERSION}: simulate an OSPFv2 area behind one adjacency

        Usage:
          ospfv2 run TOPOLOGY.yml [options]    bring up the adjacency with the router under test
          ospfv2 demo [TOPOLOGY.yml] [options] run against a built-in peer (no router, no root)
          ospfv2 show TOPOLOGY.yml [options]   print the LSDB the topology generates
          ospfv2 export TOPOLOGY.yml -f FMT    dot (Graphviz), json or yaml
          ospfv2 check TOPOLOGY.yml            validate and summarize
          ospfv2 init [--grid CxR]             print a starter topology
          ospfv2 lab new DIR [--no-git]        copy the router lab template to DIR
          ospfv2 lab new DIR --containerlab    the containerlab lab: a ring of FRR, ospfd and BIRD
          ospfv2 capture [-i IFACE] [-r FILE]  OSPF packets dissected, one JSON line each
          ospfv2 -i ADDR/LEN -g CxR ...        original command line (ospfv2 -h for flags)

        Run options:
          -w, --web [[ADDR:]PORT]   serve the dashboard (default 127.0.0.1:8080)
          -c, --console irb|none    interactive console (default irb, none with --web)
          -l, --log FILE            protocol trace (default ospfv2.log, '-' for stdout)
          -i, --interface ADDR/LEN  override simulator.interface
          -r, --router-id ID        override simulator.router_id
          -a, --area ID             override simulator.area
              --device DEV          bind the raw socket to DEV
          -d, --debug               hex dump packets in the trace

        Topology files are described in README.md and examples/.
      TXT
    end

    private

    # ---- commands

    def cmd_run(argv)
      opts = run_options(argv)
      topo = load_topology(argv.shift || raise(ArgumentError, 'run needs a topology file (try: ospfv2 init > lab.yml)'), opts)
      sim = Simulator.new(topo, log: open_log(opts[:log]), debug: opts[:debug])
      serve(sim, opts)
    end

    def cmd_demo(argv)
      opts = run_options(argv)
      path = argv.shift
      topo = path ? load_topology(path, opts) : demo_topology(opts)
      hub = Transport::Hub.new
      s = topo.settings
      sim = Simulator.new(topo, transport: Transport::Loopback.new(hub, s.address), log: open_log(opts[:log] || File::NULL),
                                debug: opts[:debug])
      net = IPAddr.new(s.interface)
      peer_addr = [2, 1, 3].map { |i| IP.create(net.to_i + i).to_s }.find { |a| a != s.address }
      peer = Neighbor.new(router_id: '2.2.2.2', area_id: s.area, src_addr: "#{peer_addr}/#{IPAddr.new(s.interface).prefix}",
                          hello_interval: s.hello_interval, dead_interval: s.dead_interval,
                          network_type: s.network_type, transport: Transport::Loopback.new(hub, peer_addr),
                          log: File.open(File::NULL, 'w'))
      peer.ls_db = LSDB::LinkStateDatabase.new(area_id: s.area)
      peer.start
      @out.puts "demo: built-in peer 2.2.2.2 at #{peer_addr} plays the router under test"
      serve(sim, opts) { |console| console&.define_singleton_method(:peer) { peer } }
    ensure
      peer&.stop
    end

    def cmd_show(argv)
      fmt = :junos
      verbose = false
      type = nil
      OptionParser.new do |o|
        o.on('-f', '--format FMT', %w[junos ios plain json]) { |f| fmt = f.to_sym }
        o.on('-v', '--verbose') { verbose = true }
        o.on('-t', '--type TYPE', %w[router network summary asbr_summary as_external]) { |t| type = t.to_sym }
      end.parse!(argv)
      sim = Simulator.new(load_topology(argv.shift || raise(ArgumentError, 'show needs a topology file')))
      if fmt == :json
        rows = sim.lsdb_rows
        rows = rows.select { |r| r[:type] == type } if type
        @out.puts JSON.pretty_generate(rows)
      elsif type
        sim.ls_db.__send__("all_#{type}").each { |l| @out.puts(verbose ? l.__send__(fmt == :plain ? :to_s_verbose : :"to_s_#{fmt}_verbose") : l.__send__(fmt == :plain ? :to_s : :"to_s_#{fmt}")) }
      else
        @out.puts sim.lsdb_text(fmt, verbose: verbose)
      end
      0
    end

    def cmd_export(argv)
      fmt = 'dot'
      OptionParser.new { |o| o.on('-f', '--format FMT', %w[dot json yaml]) { |f| fmt = f } }.parse!(argv)
      topo = load_topology(argv.shift || raise(ArgumentError, 'export needs a topology file'))
      @out.puts case fmt
                when 'json' then JSON.pretty_generate(topo.to_h)
                when 'yaml' then topo.to_yaml
                else to_dot(topo)
                end
      0
    end

    def cmd_check(argv)
      path = argv.shift || raise(ArgumentError, 'check needs a topology file')
      topo = load_topology(path)
      sim = Simulator.new(topo)
      c = topo.counts
      s = topo.settings
      @out.puts "#{path}: OK"
      @out.puts "  simulator  #{IP.create(s.router_id)} on #{s.interface} area #{IP.create(s.area)} (#{s.network_type}, hello #{s.hello_interval}s)"
      @out.puts "  routers    #{c[:routers]}  links #{c[:links]} (#{topo.links.count { |l| !l.up? }} down)"
      @out.puts "  prefixes   #{c[:networks]} stub, #{c[:summaries]} summary, #{c[:asbr_summaries]} asbr-summary, #{c[:externals]} external"
      @out.puts "  lsdb       #{sim.ls_db.size} LSAs, #{sim.ls_db.all.sum { |l| l.encode.bytesize }} bytes"
      0
    end

    LAB_TEMPLATE = File.expand_path('../../examples/lab', __dir__)
    CLAB_TEMPLATE = File.expand_path('../../examples/clab-lab', __dir__)

    # Copies the router lab template into a new folder and makes it a git
    # repository, so saved configurations have history. --containerlab
    # copies the containerlab lab instead: a ring of point-to-point links.
    def cmd_lab(argv)
      sub = argv.shift
      raise ArgumentError, "lab needs a subcommand: lab new DIR" unless sub == 'new'
      git = true
      clab = false
      OptionParser.new do |o|
        o.on('--no-git') { git = false }
        o.on('--containerlab') { clab = true }
      end.parse!(argv)
      dir = argv.shift or raise ArgumentError, 'lab new needs a folder, for example: ospfv2 lab new ~/labs/ospf-lab'
      dir = File.expand_path(dir)
      raise ArgumentError, "#{dir} exists and is not empty" if File.exist?(dir) && !(File.directory?(dir) && Dir.empty?(dir))
      begin
        CLI.copy_lab(clab ? CLAB_TEMPLATE : LAB_TEMPLATE, dir)
      rescue Errno::EACCES, Errno::EPERM => e
        parent = File.dirname(dir)
        hint = File.exist?(parent) && !File.writable?(parent) ? " (#{parent} is not writable: sudo chown $USER: #{parent})" : ''
        raise ArgumentError, "cannot make the lab folder: #{e.message}#{hint}"
      end
      @out.puts "lab created in #{dir}"
      @out.puts(lab_git_init(dir, clab ? 'examples/clab-lab' : 'examples/lab')) if git
      @out.puts(clab ? <<~CLAB : <<~TXT)

        Deploy it with containerlab (images ospfv2 and ospfv2-bird first):
          cd #{dir} && sudo containerlab deploy -t ospf-ring.clab.yml
      CLAB

        Use it from the ospfv2 folder:
          export LAB=#{dir}
          docker compose --profile frr up -d sim frr
      TXT
      0
    end

    # Copies a lab folder, leaving out what its .gitignore lists: files a
    # router wrote there when the template itself was in use (no LAB set).
    # Those can belong to root and are no part of a new lab.
    def self.copy_lab(src, dst)
      ignore = File.readlines(File.join(src, '.gitignore'), chomp: true).map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
      FileUtils.mkdir_p(dst)
      Dir.glob('**/*', File::FNM_DOTMATCH, base: src).sort.each do |rel|
        next if File.basename(rel) == '.' || ignore.any? { |pat| File.fnmatch?(pat, File.basename(rel), File::FNM_DOTMATCH) }
        from = File.join(src, rel)
        to = File.join(dst, rel)
        if File.directory?(from)
          FileUtils.mkdir_p(to)
        else
          FileUtils.cp(from, to)
          File.chmod(File.stat(from).mode & 0o777, to)
        end
      end
    end

    def lab_git_init(dir, from = 'examples/lab')
      # The lab's commits are configuration snapshots: they carry the lab's
      # own identity, set in this repository only.
      ok = system('git', '-C', dir, 'init', '-q', out: File::NULL, err: File::NULL) &&
           system('git', '-C', dir, 'config', 'user.name', 'lab', out: File::NULL, err: File::NULL) &&
           system('git', '-C', dir, 'config', 'user.email', 'lab@configs', out: File::NULL, err: File::NULL) &&
           system('git', '-C', dir, 'add', '-A', out: File::NULL, err: File::NULL)
      return 'git: not available, the lab folder has no history' unless ok
      if system('git', '-C', dir, 'commit', '-q', '-m', "Lab created from ospfv2 #{from}", out: File::NULL, err: File::NULL)
        'git: repository created with a first commit'
      else
        'git: repository created; the first commit failed (set git user.name and user.email, then commit)'
      end
    end

    # Captures OSPF packets (tcpdump on an interface, or a pcap file or
    # stream) and prints each one dissected, one JSON line per message:
    #
    #   {"capture": {"interface":, "link":, "filter":}}   first
    #   {"packet": {"seq":, "time":, "length":, "hex":, "summary":, "fields":, "errors":}}
    #   {"error": "..."}                                    and the exit status is 1
    #
    # A console runs it next to a router: docker run --network container:NAME.
    def cmd_capture(argv)
      require 'json'
      require 'time'
      require_relative 'pcap'
      require_relative 'dissect'
      opts = { interface: 'eth0', filter: 'ip proto 89', count: nil, file: nil }
      OptionParser.new do |o|
        o.on('-i', '--interface IFACE') { |v| opts[:interface] = v }
        o.on('-r', '--read FILE', 'a pcap file, - for stdin') { |v| opts[:file] = v }
        o.on('-f', '--filter EXPR') { |v| opts[:filter] = v }
        o.on('-c', '--count N', Integer) { |v| opts[:count] = v }
      end.parse!(argv)
      $stdout.sync = true
      io, pid = capture_source(opts)
      reader = Pcap::Reader.new(io)
      link = Dissect::LINKS.fetch(reader.link) { raise ArgumentError, "link type #{reader.link} is not supported" }
      @out.puts JSON.generate(capture: { interface: opts[:file] ? nil : opts[:interface], file: opts[:file], link: link, filter: opts[:filter] })
      seq = 0
      reader.each do |rec|
        seq += 1
        d = Dissect.frame(rec.data, link: link).to_h
        @out.puts JSON.generate(packet: { seq: seq, time: rec.time.utc.iso8601(6), length: rec.length,
                                          hex: rec.data.unpack1('H*') }.merge(d))
        break if opts[:count] && seq >= opts[:count]
      end
      0
    rescue Pcap::Error, ArgumentError, SystemCallError => e
      @out.puts JSON.generate(error: e.message)
      1
    ensure
      if pid
        Process.kill('TERM', pid) rescue nil
        Process.wait(pid) rescue nil
      end
    end

    def capture_source(opts)
      return [$stdin.binmode, nil] if opts[:file] == '-'
      return [File.open(opts[:file], 'rb'), nil] if opts[:file]
      r, w = IO.pipe
      pid = Process.spawn('tcpdump', '-U', '-n', '-s', '0', '-w', '-', '-i', opts[:interface], *opts[:filter].split,
                          out: w, err: File::NULL)
      w.close
      [r, pid]
    rescue Errno::ENOENT
      raise ArgumentError, 'tcpdump is not installed here'
    end

    def cmd_init(argv)
      grid = '3x3'
      iface = '192.168.1.123/24'
      OptionParser.new do |o|
        o.on('-g', '--grid CxR') { |g| grid = g }
        o.on('-i', '--interface ADDR/LEN') { |i| iface = i }
      end.parse!(argv)
      cols, rows = grid.split('x').map(&:to_i)
      @out.puts <<~YAML
        # ospfv2 topology. Edit, then: ospfv2 check lab.yml && ospfv2 run lab.yml --web 8080
        simulator:
          router_id: 1.1.1.1
          interface: #{iface}   # our address on the segment shared with the router under test
          area: 0.0.0.0
          hello_interval: 10           # must match the router under test
          network_type: broadcast      # or p2p

        grid:                          # routers named r<row>c<col>, router id 0.<row>.0.<col>
          columns: #{cols}
          rows: #{rows}
          metric: 10

        routers:
          - name: edge
            id: 10.0.0.1
            loopback: 10.255.0.1
            summaries:
              - { prefix: 30.0.0.0/24, count: 10 }
            externals:
              - { prefix: 50.0.0.0/24, count: 20, metric: 20, type: 2 }

        links:
          - { from: r#{rows}c#{cols}, to: edge, metric: 10 }
      YAML
      0
    end

    def legacy(argv)
      o = OptParse.parse(argv)
      topo = legacy_topology(o)
      opts = { console: o.console, log: o.log_fname == $stdout ? '-' : o.log_fname, debug: o.debug, web: o.web }
      serve(Simulator.new(topo, log: open_log(opts[:log]), debug: o.debug), opts)
    end

    public

    # Topology equivalent to the original command line flags.
    def legacy_topology(o)
      topo = Topology.new
      topo.configure(router_id: o.router_id, interface: "#{o.ipaddr}/#{IPAddr.new("0.0.0.0/#{o.netmask}").prefix}", area: o.area_id,
                     hello_interval: o.hello_int, dead_interval: o.dead_int, network_type: o.network_type == :p2p ? 'p2p' : 'broadcast')
      topo.configure(device: o.device) if o.device
      topo.configure_lsdb(link_prefix: o.base_link_addr, refresh_time: o.ls_refresh_time)
      cols, rows = o.grid
      if cols.to_i.positive? && rows.to_i.positive?
        topo.add_grid(columns: cols, rows: rows, base_router_id: o.base_router_id)
        abrs = ['r1c1', rows > 1 ? 'r2c1' : nil].compact
        per = o.num_sum / abrs.size
        abrs.each_with_index do |name, i|
          next if per.zero?
          r = topo.routers[name]
          r.summaries.concat(Array.new(per) { |k| Topology::Prefix.new(prefix: IP.nth_network(IPAddr.new('30.0.0.0/24'), i * per + k), metric: 10) })
          r.abr = true
        end
        r = topo.routers['r1c1']
        r.externals.concat(Array.new(o.num_ext) { |k| Topology::External.new(prefix: IP.nth_network(IPAddr.new('50.0.0.0/24'), k), metric: 20, type: 2, tag: 10) })
        r.asbr = o.num_ext.positive?
      end
      topo.validate!
    end

    private

    # ---- helpers

    def run_options(argv)
      opts = {}
      OptionParser.new do |o|
        o.on('-w', '--web [ADDR_PORT]') { |w| opts[:web] = w || '8080' }
        o.on('-c', '--console KIND', %w[irb none]) { |c| opts[:console] = c.to_sym }
        o.on('-l', '--log FILE') { |f| opts[:log] = f }
        o.on('-i', '--interface ADDR') { |v| (opts[:override] ||= {})[:interface] = v }
        o.on('-r', '--router-id ID') { |v| (opts[:override] ||= {})[:router_id] = v }
        o.on('-a', '--area ID') { |v| (opts[:override] ||= {})[:area] = v }
        o.on('--device DEV') { |v| (opts[:override] ||= {})[:device] = v }
        o.on('-d', '--debug') { opts[:debug] = true }
      end.parse!(argv)
      opts
    end

    def load_topology(path, opts = {})
      raise ArgumentError, "no such file: #{path}" unless File.exist?(path)
      topo = Topology.load(path)
      topo.configure(opts[:override]) if opts[:override]
      topo
    end

    def demo_topology(opts)
      Topology.build do
        simulator router_id: '1.1.1.1', interface: '192.168.1.1/24', hello_interval: 2
        grid columns: 4, rows: 3, metric: 10
        router 'edge', id: '10.0.0.1' do
          loopback '10.255.0.1'
          summaries '30.0.0.0/24', count: 10
          externals '50.0.0.0/24', count: 20, metric: 20
        end
        link 'r3c4', 'edge', metric: 5
      end.tap { |t| t.configure(opts[:override]) if opts[:override] }
    end

    def open_log(spec)
      case spec
      when nil then File.open('ospfv2.log', 'a')
      when '-' then $stdout
      when IO, StringIO then spec
      else File.open(spec, 'a')
      end
    end

    def serve(sim, opts)
      server = nil
      if opts[:web]
        require_relative 'web/server'
        host, port = parse_web(opts[:web])
        server = Web::Server.new(sim, host: host, port: port).start
        @out.puts "dashboard: http://#{host == '0.0.0.0' ? 'localhost' : host}:#{server.port}/"
      end
      sim.start
      @out.puts "neighbor: #{sim.settings.address} router-id #{IP.create(sim.settings.router_id)}, #{sim.ls_db.size} LSAs ready"
      console_kind = opts[:console] || (server ? :none : :irb)
      if console_kind == :irb && $stdin.tty?
        console = Console.new(sim)
        yield console if block_given?
        console.start_irb
      else
        yield nil if block_given?
        @out.puts 'Ctrl-C to stop'
        wait_for_signal
      end
      0
    ensure
      server&.stop
      sim&.stop
    end

    def wait_for_signal
      q = Queue.new
      %w[INT TERM].each { |sig| trap(sig) { q << sig } }
      q.pop
    end

    def parse_web(spec)
      s = spec.to_s
      return ['127.0.0.1', Integer(s)] if s.match?(/\A\d+\z/)
      host, port = s.rpartition(':').values_at(0, 2)
      [host.empty? ? '127.0.0.1' : host, Integer(port)]
    end

    def to_dot(topo)
      lines = ['graph ospf {', '  graph [overlap=false, splines=true];', '  node [shape=box, style=rounded, fontname="Helvetica"];']
      topo.all_routers.each do |r|
        label = "#{r.name}\\n#{r.id_ip}"
        extras = []
        extras << "#{r.summaries.size} sum" unless r.summaries.empty?
        extras << "#{r.externals.size} ext" unless r.externals.empty?
        label += "\\n#{extras.join(', ')}" unless extras.empty?
        attrs = ["label=\"#{label}\""]
        attrs << 'style="rounded,filled", fillcolor="#dbeafe"' if r.name == Topology::SIM
        attrs << "pos=\"#{r.grid[1] * 2},#{-r.grid[0] * 2}!\"" if r.grid
        lines << "  \"#{r.name}\" [#{attrs.join(', ')}];"
      end
      lines << '  "dut" [label="router under test", shape=ellipse];'
      lines << '  "sim" -- "dut" [style=bold];'
      topo.links.each do |l|
        attrs = ["label=\"#{l.metric}\""]
        attrs << 'style=dashed, color=gray' unless l.up?
        lines << "  \"#{l.from}\" -- \"#{l.to}\" [#{attrs.join(', ')}];"
      end
      lines << '}'
      lines.join("\n")
    end
  end
end
