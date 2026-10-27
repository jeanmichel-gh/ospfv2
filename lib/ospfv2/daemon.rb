# frozen_string_literal: true

require 'fileutils'
require_relative 'core'
require_relative 'config/model'
require_relative 'daemon/system'
require_relative 'daemon/views'

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
    RECHECK = 5 # seconds between checks of the host interfaces

    attr_reader :loop, :running, :candidate, :instance, :pending, :started_at

    # transport: ->(ifname, ip) { a Transport } for each non-passive interface
    def initialize(config_path:, loop: nil, system: System.new, logger: nil,
                   transport: ->(ifname, ip) { Transport::RawSocket.new(ip, interface: ifname) })
      @config_path = config_path
      @loop = loop || EventLoop.new
      @system = system
      @logger = logger
      @transport = transport
      @running = Config::Tree.new
      @candidate = Config::Tree.new
      @model = nil
      @instance = nil
      @pending = {}      # ifname => why it is not running
      @applied = {}      # ifname => options the interface runs with
      @lock = Mutex.new  # guards candidate, running and the files
      @commits = []
    end

    # Loads the saved configuration and commits it. A missing file starts
    # an empty router; a broken one is reported and nothing runs.
    def start
      @loop.start unless @loop.running? || @loop.clock.fake?
      @started_at = @loop.clock.wall
      text = File.exist?(@config_path) ? File.read(@config_path) : ''
      @lock.synchronize do
        errors = @candidate.load(text)
        unless errors.empty?
          log(:error, "#{@config_path}: #{errors.join('; ')}")
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
        @instance&.stop
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
    def commit(check: false, save: true, comment: nil)
      @lock.synchronize do
        model = Config::Model.new(@candidate)
        changes = @running.compare(@candidate)
        return { ok: true, errors: [], warnings: model.warnings, changes: changes } if check

        @loop.call { apply(model) }
        previous = @running
        @running = @candidate.dup
        @model = model
        if save
          save_rollback(previous)
          write_config(@running)
        end
        @commits.unshift({ time: @loop.clock.wall, comment: comment, changes: changes.size })
        @commits.pop while @commits.size > ROLLBACKS + 1
        log(:info, "commit#{comment ? " (#{comment})" : ''}: #{changes.size} change(s)")
        { ok: true, errors: [], warnings: model.warnings + pending_warnings, changes: changes }
      end
    rescue Config::Error => e
      { ok: false, errors: e.message.lines.map(&:chomp), warnings: [], changes: [] }
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

    # Logs to the logger and to the router's event list (show ospf log).
    def log(level, message)
      @logger&.call(level, message)
      record = -> { @instance&.record(level, message) }
      @loop.on_loop_thread? || !@loop.running? ? record.call : @loop.post(&record)
    end

    private

    # ---- applying a model, on the loop thread ----

    def apply(model)
      if @instance.nil? || @instance.router_id_s != model.router_id
        if @instance
          log(:info, "router id #{@instance.router_id_s} -> #{model.router_id}: restarting OSPF")
          @instance.stop
        end
        @instance = Core::Instance.new(router_id: model.router_id, loop: @loop, logger: @logger)
        @applied = {}
        @pending = {}
        @desired = model.interfaces
        sync_interfaces
        @instance.start
      else
        @desired = model.interfaces
        sync_interfaces
      end
    end

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
      applied[:address] == link.address && applied.except(:address, *LIVE) == want.except(*LIVE)
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
      @applied[name] = want.merge(address: have[:address])
    end

    def add(name, want, link)
      opts = want.except(:area)
      ip = link.address.split('/').first
      transport = opts[:passive] ? nil : @transport.call(name, ip)
      @instance.add_interface(name: name, address: link.address, area: want[:area], transport: transport, **opts)
      @applied[name] = want.merge(address: link.address)
      @pending.delete(name)
      log(:info, "interface #{name}: running OSPF on #{link.address} in area #{want[:area]}")
    rescue ArgumentError, PermissionError => e
      @pending[name] = e.message
      log(:error, "interface #{name}: #{e.message}")
    end

    def remove(name)
      @instance.remove_interface(name)
      @applied.delete(name)
    end

    def recheck_links
      sync_interfaces if @instance && @desired
    end

    def pending_warnings
      @pending.map { |name, why| "interface #{name}: #{why}" }
    end

    # ---- files ----

    def write_config(tree)
      FileUtils.mkdir_p(File.dirname(@config_path))
      tmp = "#{@config_path}.tmp"
      body = "# ospfd configuration, saved by commit #{@loop.clock.wall.utc.strftime('%F %T')} UTC\n" \
             "#{tree.to_set(hide: false).join("\n")}\n"
      File.open(tmp, 'w', 0o600) { |f| f.write(body) }
      File.rename(tmp, @config_path)
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
