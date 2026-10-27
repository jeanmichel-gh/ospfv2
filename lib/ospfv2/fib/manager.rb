# frozen_string_literal: true

module OSPFv2
  module Fib
    # Keeps the kernel's OSPF routes in line with the router's table.
    # Runs on the event loop.
    #
    #   fib = Fib::Manager.new(loop: loop, backend: Fib::Netlink.new)
    #   fib.attach(instance)    # installs and follows instance.routes
    #   fib.detach              # withdraws everything
    #
    # What goes in: every route whose next hops all name a gateway. A
    # network we sit on is the kernel's connected route already, so a route
    # with a direct hop stays out.
    #
    # Order: adds and changes first (each a replace, so traffic never sees
    # a hole), deletes last.
    #
    # Startup: routes of ours already in the kernel (a restart) are kept
    # until the router has converged, or +hold+ seconds at most, then the
    # ones OSPF no longer wants go. A route the kernel refuses is retried
    # every +retry+ seconds. Every +reconcile+ seconds the kernel is read
    # back and any drift repaired, with a log line per repair.
    class Manager
      DEFAULTS = { metric: 20, hold: 60, retry: 5, reconcile: 60 }.freeze

      # One row of #status.
      Entry = Struct.new(:key, :want, :have, :state, :error, keyword_init: true)

      attr_reader :backend, :metric, :failed, :repairs, :last_reconcile

      def initialize(loop:, backend:, logger: nil, **opts)
        o = DEFAULTS.merge(opts)
        @loop = loop
        @backend = backend
        @logger = logger
        @metric = o[:metric]
        @hold_for = o[:hold]
        @retry_every = o[:retry]
        @reconcile_every = o[:reconcile]
        @installed = {}   # kernel_key => Route, what we believe the kernel holds
        @failed = {}      # kernel_key => message, routes the kernel refused
        @want = {}
        @instance = nil
        @holding = false
        @repairs = 0
        @last_reconcile = nil
      end

      # Starts following +instance+. Reads what the kernel holds first.
      def attach(instance)
        detach if @instance
        @instance = instance
        @installed = read_kernel || {}
        unless @installed.empty?
          @holding = true
          log(:info, "kernel holds #{@installed.size} OSPF routes from before; keeping them until converged")
          @hold_timer = @loop.after(@hold_for, :fib_hold) { end_hold('hold time is up') }
          @hold_check = @loop.every(1, :fib_hold_check) { end_hold('converged') if converged? }
        end
        instance.on_route_change { sync if @instance.equal?(instance) }
        @retry_timer = @loop.timer(@retry_every, :fib_retry) { sync }
        @reconcile_timer = @loop.every(@reconcile_every, :fib_reconcile) { reconcile }
        sync
        self
      end

      # Withdraws every route we installed and stops following the router.
      def detach(withdraw: true)
        [@hold_timer, @hold_check, @retry_timer, @reconcile_timer].each { |t| t&.cancel }
        @instance = nil
        @holding = false
        @want = {}
        sync(force: true) if withdraw
        self
      end

      # New metric: routes are re-added at it and the old ones removed.
      def metric=(value)
        return if value == @metric
        @metric = value
        sync
      end

      def holding? = @holding

      # Brings the kernel to the wanted state. Changes first, deletes last.
      def sync(force: false)
        @want = wanted unless force
        @want.each_value do |r|
          next if @installed[r.kernel_key] == r
          apply(r) { @backend.replace(r) }
        end
        @installed.values.each do |r|
          next if @want.key?(r.kernel_key) || (@holding && !force)
          apply(r, delete: true) { @backend.delete(r) }
        end
        @failed.select! { |k, _| @want.key?(k) || @installed.key?(k) }
        if @failed.empty?
          @retry_timer&.cancel
        elsif @retry_timer && !@retry_timer.active?
          @retry_timer.restart
        end
      end

      # Reads the kernel back and repairs what differs from what we put
      # there: a route someone deleted, changed or added under our id.
      def reconcile
        kernel = read_kernel or return
        @last_reconcile = @loop.clock.wall
        (kernel.keys | @installed.keys).each do |k|
          next if kernel[k] == @installed[k]
          why = if kernel[k].nil? then 'missing from the kernel'
                elsif @installed[k].nil? then 'in the kernel, not ours to keep'
                else 'changed in the kernel'
                end
          @repairs += 1
          log(:warn, "FIB repair: #{(kernel[k] || @installed[k]).dest_s} #{why}")
        end
        @installed = kernel
        sync
      end

      # Every route we want or the kernel holds, compared. With +fresh+,
      # the kernel is read now rather than trusted from memory.
      def status(fresh: false)
        have = fresh ? (read_kernel || @installed) : @installed
        keys = (@want.keys | have.keys).sort
        keys.map do |k|
          want = @want[k]
          got = have[k]
          state = if @failed[k] then :failed
                  elsif want && got == want then :installed
                  elsif want && got then :different
                  elsif want then :missing
                  elsif @holding then :held
                  else :extra
                  end
          Entry.new(key: k, want: want, have: got, state: state, error: @failed[k])
        end
      end

      private

      def wanted
        return {} unless @instance
        @instance.routes.each_value.filter_map do |r|
          next if r.next_hops.empty? || r.next_hops.any? { |h| h.gateway.nil? }
          f = Route.new(r.prefix, r.prefix_len, r.next_hops.map { |h| [h.interface, h.gateway] }, @metric)
          [f.kernel_key, f]
        end.to_h
      end

      def apply(route, delete: false)
        yield
        k = route.kernel_key
        delete ? @installed.delete(k) : @installed[k] = route
        log(@failed.delete(k) ? :info : :debug, "FIB #{delete ? 'deleted' : 'installed'} #{route}")
      rescue Error => e
        k = route.kernel_key
        log(:warn, "FIB could not #{delete ? 'delete' : 'install'} #{route}: #{e.message}, will retry") unless @failed[k] == e.message
        @failed[k] = e.message
      end

      def read_kernel
        @backend.dump.to_h { |r| [r.kernel_key, r] }
      rescue Error => e
        log(:warn, "FIB could not read the kernel table: #{e.message}")
        nil
      end

      # Adjacencies settled and the database quiet for a while: SPF back in
      # its RFC 8405 quiet state, so no route has changed for its holddown
      # (10 s). What OSPF wants now is what it will want.
      def converged?
        return false unless @instance
        nbrs = @instance.neighbors
        nbrs.any?(&:full?) && nbrs.none? { |n| %i[exstart exchange loading].include?(n.state) } &&
          @instance.spf.state == :quiet && @instance.spf.runs.positive?
      end

      def end_hold(why)
        return unless @holding
        @holding = false
        @hold_timer&.cancel
        @hold_check&.cancel
        stale = @installed.keys - @want.keys
        log(:info, "FIB: #{why}, removing #{stale.size} routes OSPF no longer has") unless stale.empty?
        sync
      end

      def log(level, msg)
        @logger&.call(level, msg)
      end
    end
  end
end
