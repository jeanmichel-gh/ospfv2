# frozen_string_literal: true

require 'fileutils'
require_relative 'core'
require_relative 'config/model'
require_relative 'fib'
require_relative 'daemon/system'
require_relative 'daemon/views'
require_relative 'daemon/events'

module OSPFv2
  # ospfd: runs the router core from a configuration file and answers the
  # management API (Daemon::Api) that ospf-cli talks to.
  #
  #   d = Daemon.new(config_path: '/etc/ospfv2/ospfd.conf')
  #   d.start            # loads the file and commits it
  #   d.configure(['set protocols ospf area 0 interface eth1'])
  #   d.commit
  #
  # The configuration is shared: one candidate for every CLI session, as in
  # Junos "configure". Commit checks it (Config::Model), applies the
  # difference to the running router, saves it, and keeps the previous
  # versions as rollback 1..9.
  class Daemon
    ROLLBACKS = 9
    COMMIT_EVENT_LINES = 50 # statements listed in a commit event; the count covers all
    RECHECK = 5          # seconds between checks of the host interfaces
    APPLY_TIMEOUT = 120  # seconds a commit waits for the router to take it

    # Its own timers by name, for show timers.
    def timers = { link_recheck: @recheck }.compact

    attr_reader :loop, :running, :candidate, :instance, :started_at, :broken_file, :fib, :fib_error, :events

    # In-memory kernel table: what a Daemon installs into unless told
    # otherwise, so tests and embedding never touch the host. bin/ospfd
    # passes NETLINK.
    MEMORY_FIB = ->(protocol:, table:) { Fib::Memory.new }
    NETLINK_FIB = lambda do |protocol:, table:|
      require_relative 'fib/netlink'
      Fib::Netlink.new(protocol: protocol, table: table)
    end

    # transport: ->(ifname, ip) { a Transport } for each non-passive interface
    # fib:       ->(protocol:, table:) { a Fib backend }
    def initialize(config_path:, loop: nil, system: System.new, logger: nil,
                   transport: ->(ifname, ip) { Transport::RawSocket.new(ip, interface: ifname) },
                   fib: MEMORY_FIB)
      @config_path = config_path
      @loop = loop || EventLoop.new
      @system = system
      @logger = logger
      @transport = transport
      @fib_factory = fib
      @fib = nil
      @fib_error = nil
      @kernel = nil
      @running = Config::Tree.new
      @candidate = Config::Tree.new
      @model = nil
      @instance = nil
      @pending = {}      # ifname => why it is not running
      @applied = {}      # ifname => options the interface runs with
      @lock = Mutex.new  # guards candidate, running and the files
      @events = Events.new
      @commits = []
    end

    # Loads the saved configuration and commits it. A missing file starts
    # an empty router. A broken one runs nothing: it is copied to
    # <file>.broken first, so the next commit cannot lose it, and the
    # errors are logged with secrets hidden.
    def start
      @loop.start unless @loop.running? || @loop.clock.fake?
      @started_at = @loop.clock.wall
      text = File.exist?(@config_path) ? File.read(@config_path) : ''
      @lock.synchronize do
        errors = @candidate.load(text)
        unless errors.empty?
          @broken_file = "#{@config_path}.broken"
          File.open(@broken_file, 'w', 0o600) { |f| f.write(text) }
          log(:error, "#{@config_path} not loaded, kept as #{@broken_file}: #{errors.join('; ')}")
          @candidate = Config::Tree.new
        end
      end
      result = commit(save: false, comment: 'startup')
      log(:error, "startup configuration not applied: #{result[:errors].join('; ')}") unless result[:ok]
      @loop.call { @recheck = @loop.every(RECHECK, :link_recheck) { recheck_links } }
      self
    end

    def stop
      @loop.call do
        @recheck&.cancel
        @instance&.stop # its routes leave the kernel with it
        stop_fib
      end
      @loop.stop if @loop.running?
      self
    end

    # ---- configuration ----

    # Applies set/delete lines to the candidate. Returns the errors.
    def configure(lines)
      @lock.synchronize { @candidate.load(Array(lines).join("\n")) }
    end

    def discard
      @lock.synchronize { @candidate = @running.dup }
    end

    # Replaces the candidate with +text+ (set/delete lines), like Junos
    # "load override". Raises Config::Error and keeps the candidate when
    # +text+ has errors.
    def load_override(text)
      tree = Config::Tree.parse(text)
      @lock.synchronize { @candidate = tree }
      nil
    end

    def compare
      @lock.synchronize { @running.compare(@candidate) }
    end

    def show_configuration(candidate: false, format: :curly)
      @lock.synchronize do
        t = candidate ? @candidate : @running
        format == :set ? t.to_set.join("\n") : t.to_curly
      end
    end

    def candidate_changed?
      @lock.synchronize { @running != @candidate }
    end

    # Checks the candidate and makes it the running configuration.
    # Returns { ok:, errors:, warnings:, changes: }.
    #
    # Order matters. The new file is written aside first, so a disk
    # problem stops the commit before the router changes. Then the router
    # takes the model; anything an interface cannot do yet (missing,
    # down, transport refused) becomes a warning and is retried every
    # RECHECK seconds. Then the file replaces the old one and the old one
    # becomes rollback 1. Saved commits are the ones history lists, so
    # history numbers match rollback numbers.
    def commit(check: false, save: true, comment: nil)
      comment = clean_comment(comment)
      @lock.synchronize do
        model = Config::Model.new(@candidate)
        changes = @running.compare(@candidate)
        return { ok: true, errors: [], warnings: model.warnings, changes: changes } if check

        staged = save ? stage_config(@candidate) : nil
        warnings = model.warnings + apply_on_loop(model)
        previous = @running
        @running = @candidate.dup
        @model = model
        if staged
          begin
            save_rollback(previous)
          rescue SystemCallError => e
            warnings << "rollback 1 not saved: #{e.message}"
          end
          begin
            File.rename(staged, @config_path)
          rescue SystemCallError => e
            warnings << "applied, but #{@config_path} not saved: #{e.message}"
          end
          @commits.unshift({ time: @loop.clock.wall, comment: comment, changes: changes.size })
          @commits.pop while @commits.size > ROLLBACKS
        end
        @broken_file = nil if save
        log(:info, "commit#{comment ? " (#{comment})" : ''}: #{changes.size} change(s)",
            kind: :commit, comment: comment, changes: changes.size, statements: changes.first(COMMIT_EVENT_LINES),
            saved: !staged.nil?)
        { ok: true, errors: [], warnings: warnings, changes: changes }
      end
    rescue Config::Error => e
      { ok: false, errors: e.message.lines.map(&:chomp), warnings: [], changes: [] }
    rescue SystemCallError => e
      { ok: false, errors: ["cannot save #{@config_path}: #{e.message}; nothing changed"], warnings: [], changes: [] }
    end

    # Loads rollback +n+ (0 is the running configuration) into the
    # candidate. Commit to apply it.
    def rollback(n = 0)
      n = Integer(n)
      raise Config::Error, "rollback must be 0..#{ROLLBACKS}" unless n.between?(0, ROLLBACKS)
      @lock.synchronize do
        if n.zero?
          @candidate = @running.dup
        else
          path = rollback_path(n)
          raise Config::Error, "rollback #{n} does not exist" unless File.exist?(path)
          @candidate = Config::Tree.parse(File.read(path))
        end
      end
      nil
    end

    def commit_history
      @lock.synchronize { @commits.map(&:dup) }
    end

    # Interfaces configured but not running, and why. Read on the loop.
    def pending
      @loop.call { @pending.dup }
    end

    # ---- operational state, for Daemon::Views ----

    def views = Views.new(self)

    # Takes every neighbor (or those with +router_id+) down, so the
    # adjacencies form again.
    def clear_neighbors(router_id = nil)
      @loop.call do
        next 0 unless @instance
        rid = router_id && Core::Addr.to_i(router_id)
        nbrs = @instance.neighbors.select { |n| rid.nil? || n.router_id == rid }
        nbrs.each { |n| n.kill('cleared by operator') }
        nbrs.size
      end
    end

    # Logs to the logger, to the router's event list (show ospf events)
    # and to the event stream. With no router yet, to the stream directly.
    def log(level, message, kind: :log, **data)
      @logger&.call(level, message)
      return if level == :debug # logger only, as Instance#log
      record = lambda do
        if @instance
          @instance.record(level, message, kind: kind, **data)
        else
          @events.publish(time: @loop.clock.wall, level: level, kind: kind, message: message, data: data)
        end
      end
      @loop.on_loop_thread? || !@loop.running? ? record.call : @loop.post(&record)
    end

    private

    def publish_core_event(ev)
      @events.publish(time: ev.time, level: ev.level, kind: ev.kind || :log, message: ev.message,
                      interface: ev.interface, data: ev.data || {})
    end

    # ---- applying a model, on the loop thread ----

    # Runs apply on the loop and returns the warnings. If the loop is too
    # busy to answer in time, the apply is still queued and will run; the
    # caller is told so rather than given a false error.
    def apply_on_loop(model)
      @loop.call(timeout: APPLY_TIMEOUT) do
        apply(model)
        @pending.map { |name, why| "interface #{name}: #{why}" }
      rescue StandardError => e
        # Not expected: every interface failure is caught in add. What was
        # applied stays, and the link recheck keeps converging on @desired.
        log(:error, "commit applied with an error: #{e.class}: #{e.message}")
        ["commit applied with an error (#{e.class}: #{e.message}); see show ospf interface"]
      end
    rescue EventLoop::Stalled
      ['the router is busy; the change is queued and applies when it catches up']
    end

    def apply(model)
      @desired = model.interfaces
      if @instance.nil? || @instance.router_id_s != model.router_id
        if @instance
          log(:info, "router id #{@instance.router_id_s} -> #{model.router_id}: restarting OSPF")
          @instance.stop(flush: true)
        end
        # Start first, then add: every interface then goes through add,
        # whose failures are contained.
        @instance = Core::Instance.new(router_id: model.router_id, loop: @loop, logger: @logger)
        @instance.on_event { |ev| publish_core_event(ev) }
        @instance.start
        @applied = {}
        @pending = {}
        @exported = nil
        @fib&.attach(@instance)
      end
      apply_kernel(model.kernel)
      apply_areas(model.areas)
      sync_interfaces
      apply_virtual_links(model.virtual_links)
      @export = model.export
      export_routes
    end

    # Area options (stub, NSSA). Becoming or ceasing to be a stub or NSSA
    # changes the options in hellos, so the area's interfaces restart and
    # neighbors start over. Other changes (default metric, no-summaries,
    # default-lsa) only change what the ABR originates.
    def apply_areas(areas)
      want = areas.to_h { |id, o| [Core::Addr.to_i(id), o] }
      have = @instance.area_options
      changed = (want.keys | have.keys).reject { |id| want[id] == have[id] }
      @instance.area_options = want
      changed.each do |id|
        if want[id]&.keys != have[id]&.keys
          log(:info, "area #{Core::Addr.to_s(id)}: area type changed, restarting its interfaces")
          (@instance.areas[id]&.interfaces || []).map(&:name).each { |name| remove(name) }
        else
          log(:info, "area #{Core::Addr.to_s(id)}: options changed")
          @instance.areas[id]&.schedule_origination
          @instance.spf.trigger(:area, Core::Addr.to_s(id), source: { source: 'config' })
        end
      end
    end

    # Virtual links: added, removed, or replaced when their settings change.
    def apply_virtual_links(want)
      have = @instance.virtual_links
      @applied_vls ||= {}
      (have.keys.map { |id| Core::Addr.to_s(id) } | want.keys).each do |rid|
        next if want[rid] && want[rid] == @applied_vls[rid] && have.key?(Core::Addr.to_i(rid))
        # A new key or password applies in place, as on interfaces.
        if want[rid] && @applied_vls[rid] && have.key?(Core::Addr.to_i(rid)) &&
           want[rid].except(:auth) == @applied_vls[rid].except(:auth)
          have[Core::Addr.to_i(rid)].auth = want[rid][:auth]
          @applied_vls[rid] = want[rid]
          log(:info, "virtual link to #{rid}: authentication changed")
          next
        end
        if have.key?(Core::Addr.to_i(rid))
          @instance.remove_virtual_link(rid)
          @applied_vls.delete(rid)
        end
        next unless (w = want[rid])
        @instance.add_virtual_link(neighbor: rid, transit_area: w[:transit_area], **w.except(:transit_area))
        @applied_vls[rid] = w
        log(:info, "virtual link to #{rid} through area #{w[:transit_area]} configured")
      end
    end

    # protocols ospf export: the host's networks and static routes the
    # policy accepts become AS-external-LSAs. Rechecked with the links.
    def export_routes
      # A prefix both direct and static goes out once: the first the policy
      # accepts, direct first.
      want = []
      if @export
        export_candidates.group_by { |c| [c[:prefix], c[:prefix_len]] }.each_value do |cs|
          c = cs.sort_by { |x| x[:protocol] == :direct ? 0 : 1 }.find { |x| @export.evaluate(x) }
          want << c.merge(@export.evaluate(c)) if c
        end
      end
      return if want == @exported
      @exported = want
      log(:info, "exporting #{want.size} external routes") if want.size != @instance.externals.size
      @instance.externals = want
    end

    def export_candidates
      out = []
      @system.links.each_value do |l|
        next unless l.up
        [l.address, *l.others].compact.each do |a|
          next if a.start_with?('127.')
          ip, len = a.split('/')
          len = len.to_i
          out << { protocol: :direct, prefix: Core::Addr.to_i(ip) & Core::Addr.mask(len), prefix_len: len }
        end
      end
      # A kernel we cannot read just now keeps the last list: better than
      # withdrawing every static route we advertise.
      statics = @system.static_routes
      @statics = statics if statics
      (@statics || []).each { |p, len| out << { protocol: :static, prefix: p, prefix_len: len } }
      out.uniq.sort_by { |c| [c[:prefix], c[:prefix_len], c[:protocol]] }
    end

    # routing-options kernel: a new metric applies in place; a new table
    # or protocol id withdraws our routes and installs them again there.
    def apply_kernel(k)
      unless k[:install]
        log(:info, 'kernel route install off: routes withdrawn') if @fib
        stop_fib
        sweep_old_kernel_routes(nil)
        @fib_error = nil
        @kernel = k
        return
      end
      if @fib && @kernel&.values_at(:protocol, :table) == k.values_at(:protocol, :table)
        @fib.metric = k[:metric]
      else
        stop_fib
        begin
          backend = @fib_factory.call(protocol: k[:protocol], table: k[:table])
        rescue StandardError => e
          @fib_error = "cannot open the kernel routing table: #{e.message}"
          log(:error, "#{@fib_error}; routes are computed, not installed")
          @kernel = k
          return
        end
        @fib_error = nil
        sweep_old_kernel_routes(k)
        @fib = Fib::Manager.new(loop: @loop, backend: backend, metric: k[:metric], logger: ->(l, m) { log(l, m) },
                                settled: -> { @pending.empty? })
        save_kernel_state(k)
        @fib.attach(@instance)
      end
      @kernel = k
    end

    # Where the protocol id and table we last installed with are kept, so
    # routes left by a crash are found even after they change.
    def kernel_state_path = "#{@config_path}.kernel"

    def save_kernel_state(k)
      File.write(kernel_state_path, "#{k[:protocol]} #{k[:table]}\n")
    rescue SystemCallError => e
      log(:warn, "cannot save #{kernel_state_path}: #{e.message}")
    end

    # Routes left in the kernel under settings we no longer use (a crash,
    # then a restart with another protocol id or table, or no-install)
    # are removed. +k+ is what we use now, nil for nothing.
    def sweep_old_kernel_routes(k)
      return unless File.exist?(kernel_state_path)
      protocol, table = File.read(kernel_state_path).split.map(&:to_i)
      return if k && [protocol, table] == k.values_at(:protocol, :table)
      unless protocol&.positive? && table&.positive?
        File.delete(kernel_state_path)
        return
      end
      backend = @fib_factory.call(protocol: protocol, table: table)
      begin
        old = backend.dump
        old.each { |r| backend.delete(r) }
        log(:info, "removed #{old.size} routes left under protocol #{protocol} table #{table}") unless old.empty?
      ensure
        backend.close
      end
      File.delete(kernel_state_path)
    rescue StandardError => e
      log(:warn, "cannot clean routes left under protocol #{protocol} table #{table}: #{e.message}")
    end

    def stop_fib
      return unless @fib
      @fib.detach
      @fib.backend.close
      @fib = nil
    end

    public

    # Kernel route install settings and state, read on the loop.
    def kernel_settings = @kernel

    private

    # Brings the running interfaces in line with @desired and the host.
    def sync_interfaces
      links = @system.links
      @applied.keys.each do |name|
        want = @desired[name]
        link = links[name]
        next if want && link&.up && link.address && same_except_live?(@applied[name], want, link)
        remove(name)
      end
      @desired.each do |name, want|
        if @applied.key?(name)
          update_live(name, want)
          next
        end
        link = links[name]
        why = if link.nil? then 'no such interface on this host'
              elsif !link.up then 'interface is down'
              elsif link.address.nil? then 'no IPv4 address'
              elsif link.address.start_with?('127.') && !want[:passive] then 'only a 127/8 address'
              end
        if why
          log(:warn, "interface #{name}: #{why}, will retry") unless @pending[name] == why
          @pending[name] = why
          next
        end
        add(name, want, link)
      end
      @pending.select! { |name, _| @desired.key?(name) && !@applied.key?(name) }
    end

    # Options an interface takes without being restarted.
    LIVE = %i[auth cost].freeze

    def same_except_live?(applied, want, link)
      applied[:address] == link.address && applied[:link_mtu] == link.mtu &&
        applied.except(:address, :link_mtu, *LIVE) == want.except(*LIVE)
    end

    def update_live(name, want)
      have = @applied[name]
      iface = @instance.interfaces[name]
      if have[:auth] != want[:auth]
        iface.auth = want[:auth]
        log(:info, "interface #{name}: authentication changed")
      end
      if have[:cost] != want[:cost]
        iface.cost = want[:cost] || Core::Interface::DEFAULTS[:cost]
        log(:info, "interface #{name}: cost #{iface.cost}")
      end
      @applied[name] = want.merge(address: have[:address], link_mtu: have[:link_mtu])
    end

    # A configured mtu wins; otherwise the kernel's, so DD packets say
    # what the link really carries (a containerlab veth is 9500). The DD
    # field is 16 bits, so a loopback's 65536 says 65535.
    def add(name, want, link)
      opts = want.except(:area)
      opts[:mtu] ||= [link.mtu, 65_535].min if link.mtu && link.mtu >= 576
      ip = link.address.split('/').first
      transport = opts[:passive] ? nil : @transport.call(name, ip)
      @instance.add_interface(name: name, address: link.address, area: want[:area], transport: transport, **opts)
      @applied[name] = want.merge(address: link.address, link_mtu: link.mtu)
      @pending.delete(name)
      log(:info, "interface #{name}: running OSPF on #{link.address} in area #{want[:area]}, MTU #{@instance.interfaces[name].mtu}")
    rescue StandardError => e
      # add_interface undoes itself; make sure, then retry later.
      @instance.remove_interface(name) if @instance.interfaces.key?(name)
      log(:error, "interface #{name}: #{e.message}, will retry") unless @pending[name] == e.message
      @pending[name] = e.message
    end

    def remove(name)
      @instance.remove_interface(name)
      @applied.delete(name)
    end

    def recheck_links
      return unless @instance && @desired
      sync_interfaces
      export_routes
    end

    def clean_comment(comment)
      return nil if comment.nil?
      c = comment.to_s.gsub(/[[:cntrl:]]/, ' ').strip[0, 200]
      c.empty? ? nil : c
    end

    # ---- files ----

    # Writes +tree+ next to the configuration file and returns that path.
    # Commit renames it over the file once the router has the change.
    def stage_config(tree)
      FileUtils.mkdir_p(File.dirname(@config_path))
      tmp = "#{@config_path}.tmp"
      File.delete(tmp) if File.file?(tmp)
      # No date in the file: unchanged statements give an unchanged file,
      # so a diff shows only real changes. Commit times are in the history.
      body = "# ospfd configuration, saved by commit\n" \
             "#{tree.to_set(hide: false).join("\n")}\n"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(body) }
      keep_owner_and_mode(tmp)
      tmp
    end

    # The new file takes the place of the old one, so it keeps the old
    # file's owner, group and mode, as an editor would: a configuration in
    # someone's lab folder stays theirs when ospfd runs as root. Others
    # never get access, since the file can hold authentication keys. A new
    # file stays root's, mode 0600.
    def keep_owner_and_mode(tmp)
      return unless File.file?(@config_path)
      st = File.stat(@config_path)
      File.chmod((st.mode & 0o660) | 0o600, tmp)
      File.chown(st.uid, st.gid, tmp) if [st.uid, st.gid] != [Process.euid, Process.egid]
    rescue SystemCallError => e
      log(:warn, "#{@config_path}: cannot keep its owner and mode: #{e.message}")
    end

    def rollback_path(n) = "#{@config_path}.rollback.#{n}"

    def save_rollback(previous)
      (ROLLBACKS - 1).downto(1) do |i|
        File.rename(rollback_path(i), rollback_path(i + 1)) if File.exist?(rollback_path(i))
      end
      File.open(rollback_path(1), 'w', 0o600) { |f| f.write(previous.to_set(hide: false).join("\n") + "\n") }
    end
  end
end
