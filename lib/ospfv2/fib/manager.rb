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
    # until the router has converged (+settled+ says the host side is
    # ready too), or +hold+ seconds at most, then the ones OSPF no longer
    # wants go. A database exchange still running at that point extends
    # the hold, up to twice +hold+. A route the kernel refuses is retried
    # every +retry+ seconds. Every +reconcile+ seconds the kernel is read
    # back and any drift repaired, with a log line per repair.
    class Manager
      DEFAULTS = { metric: 20, hold: 60, retry: 5, reconcile: 60 }.freeze
      EXCHANGING = %i[exstart exchange loading].freeze

      # One row of #status.
      Entry = Struct.new(:key, :want, :have, :state, :error, keyword_init: true)

      attr_reader :backend, :metric, :failed, :repairs, :last_reconcile

      # settled: ->() { true when nothing configured is still waiting to start }
      def initialize(loop:, backend:, logger: nil, settled: -> { true }, **opts)
        o = DEFAULTS.merge(opts)
        @settled = settled
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
        @detached = false
        @installed = read_kernel || {}
        unless @installed.empty?
          @holding = true
          @hold_until = @loop.now + 2 * @hold_for
          log(:info, "kernel holds #{@installed.size} OSPF routes from before; keeping them until converged")
          @hold_timer = @loop.after(@hold_for, :fib_hold) { hold_time_up }
          @hold_check = @loop.every(1, :fib_hold_check) { end_hold('converged') if converged? }
        end
        @listener = ->(_diff) { sync }
        instance.on_route_change(&@listener)
        @retry_timer = @loop.timer(@retry_every, :fib_retry) { sync }
        @reconcile_timer = @loop.every(@reconcile_every, :fib_reconcile) { reconcile }
        sync
        self
      end

      # Withdraws every route we installed and stops following the router.
      def detach(withdraw: true)
        [@hold_timer, @hold_check, @retry_timer, @reconcile_timer].each { |t| t&.cancel }
        @instance&.off_route_change(@listener)
        @instance = nil
        @detached = true
        @holding = false
        @want = {}
        if withdraw
          sync(force: true)
          unless @installed.empty?
            log(:warn, "FIB: #{@installed.size} routes could not be withdrawn and stay in the kernel")
          end
        end
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
          have = @installed[r.kernel_key]
          next if have == r
          # Only a route known to be ours is replaced: a new one must not
          # overwrite another protocol's route to the same prefix.
          apply(r) { have ? @backend.replace(r) : @backend.add(r) }
        end
        @installed.values.each do |r|
          next if @want.key?(r.kernel_key) || (@holding && !force)
          apply(r, delete: true) { @backend.delete(r) }
        end
        @failed.select! { |k, _| @want.key?(k) || @installed.key?(k) }
        if @failed.empty? || @detached
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

      # Converged when:
      # * every configured interface is running (+settled+) and none is
      #   still in Waiting, choosing its DR;
      # * every neighbor we should be adjacent with is Full, and none is
      #   still one-way (Init);
      # * the database has been quiet a while: SPF back in its RFC 8405
      #   quiet state, so no route changed for its holddown (10 s).
      # What OSPF wants then is what it will want.
      def converged?
        return false unless @instance && @settled.call
        ifaces = @instance.interfaces.values
        return false if ifaces.any? { |i| i.state == :waiting }
        nbrs = @instance.neighbors
        return false if nbrs.none?(&:full?)
        return false if nbrs.any? { |n| n.state == :init || (!n.full? && n.iface.adjacency_ok?(n)) }
        @instance.spf.state == :quiet && @instance.spf.runs.positive?
      end

      # The hold time is up. A database exchange still running is given
      # more time, up to twice the hold: cutting it short would delete
      # routes the next SPF puts back.
      def hold_time_up
        exchanging = @instance&.neighbors&.any? { |n| EXCHANGING.include?(n.state) }
        if exchanging && @loop.now < @hold_until
          @hold_timer = @loop.after(5, :fib_hold) { hold_time_up }
        else
          end_hold('hold time is up')
        end
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
