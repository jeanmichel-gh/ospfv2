# frozen_string_literal: true

require_relative 'wire'

module OSPFv2
  module Core
    # One neighbor on one interface: the RFC 2328 section 10 state machine,
    # the database exchange, LS requests and the retransmission list.
    #
    # Runs on the event loop thread only.
    class Neighbor
      STATES = %i[down attempt init two_way exstart exchange loading full].freeze
      RANK = STATES.each_with_index.to_h.freeze

      # LSA types this router understands. Anything else in a DD is a
      # SeqNumberMismatch (RFC 2328 10.6). We do not set the O bit, so
      # compliant neighbors do not offer opaque LSAs.
      SUPPORTED_TYPES = [1, 2, 3, 4, 5].freeze

      attr_reader :iface, :router_id, :address, :state, :priority, :dr, :bdr, :options,
                  :ls_request, :retransmit, :dd_seq, :last_change, :state_changes

      # Last cryptographic sequence number accepted from this neighbor.
      attr_accessor :crypto_seq

      def initialize(iface, router_id:, address:)
        @iface = iface
        @router_id = router_id
        @address = address
        @state = :down
        @priority = 0
        @dr = 0
        @bdr = 0
        @options = 0
        @master = nil
        @dd_seq = nil
        @db_summary = []
        @ls_request = {}
        @lsr_outstanding = []
        @retransmit = {}
        @rxmt_sent = {} # key => loop time the LSA last went out to this neighbor
        @last_rcvd_dd = nil
        @last_sent_dd = nil
        @last_sent_more = true
        @last_change = now
        @state_changes = 0
      end

      def instance = @iface.instance
      def loop = @iface.instance.loop
      def now = loop.now

      def at_least?(state)
        RANK.fetch(@state) >= RANK.fetch(state)
      end

      def master?
        @master == true
      end

      def full?
        @state == :full
      end

      # Hello fields this neighbor declared.
      def update_from_hello(hello, router_id: @router_id, address: @address)
        @router_id = router_id
        @address = address
        @priority = hello.priority
        @dr = hello.dr
        @bdr = hello.bdr
      end

      def declares_dr? = @dr == @address
      def declares_bdr? = @bdr == @address

      def dead_in
        @inactivity&.remaining
      end

      def to_s
        "#{Addr.to_s(@router_id)}@#{Addr.to_s(@address)}"
      end

      # Where packets for this neighbor alone go. On a point-to-point
      # network every packet goes to AllSPFRouters (RFC 2328 8.1), which
      # also works for /31 and unnumbered peers.
      def unicast_destination
        @iface.p2p? ? AllSPFRouters : @address
      end

      # ---- events (RFC 2328 10.2) ----

      def hello_received
        @inactivity ||= loop.timer(@iface.dead_interval, :inactivity) { kill('InactivityTimer') }
        @inactivity.restart
        change(:init, 'HelloReceived') if @state == :down
      end

      def two_way_received
        return unless @state == :init
        if @iface.adjacency_ok?(self)
          start_exstart('2-WayReceived')
        else
          change(:two_way, '2-WayReceived')
        end
      end

      def one_way_received
        return unless at_least?(:two_way)
        clear_lists
        change(:init, '1-WayReceived')
      end

      # AdjOK?: called after a DR election.
      def adj_ok
        if @state == :two_way && @iface.adjacency_ok?(self)
          start_exstart('AdjOK?')
        elsif at_least?(:exstart) && !@iface.adjacency_ok?(self)
          clear_lists
          change(:two_way, 'AdjOK?')
        end
      end

      # KillNbr, InactivityTimer, LLDown.
      def kill(event = 'KillNbr')
        clear_lists
        @inactivity&.cancel
        change(:down, event) unless @state == :down
      end

      def seq_number_mismatch(reason)
        return unless at_least?(:exchange)
        start_exstart("SeqNumberMismatch (#{reason})")
      end

      def bad_ls_req(reason)
        return unless at_least?(:exchange)
        start_exstart("BadLSReq (#{reason})")
      end

      # ---- database description (RFC 2328 10.6, 10.8) ----

      def receive_dd(dd)
        case @state
        when :down, :attempt, :two_way
          return
        when :init
          two_way_received
          return unless @state == :exstart
        end

        if dd.mtu > @iface.mtu && !@iface.mtu_ignore
          @iface.drop(:dd, "MTU mismatch: neighbor #{self} says #{dd.mtu}, ours is #{@iface.mtu}")
          return
        end

        case @state
        when :exstart then dd_exstart(dd)
        when :exchange then dd_exchange(dd)
        when :loading, :full
          if duplicate_dd?(dd)
            resend_last_dd unless master?
          else
            seq_number_mismatch('unexpected DD after exchange')
          end
        end
      end

      # ---- link state requests (RFC 2328 10.7, 10.9) ----

      def receive_ls_request(lsr)
        return unless at_least?(:exchange)
        lsas = []
        lsr.requests.each do |type, id, advr|
          lsa = instance.lsdb_for(type, @iface.area)&.[]([type, id, advr])
          unless lsa
            bad_ls_req("no #{LsaFields::TYPES.fetch(type, type)} #{Addr.to_s(id)} #{Addr.to_s(advr)}")
            return
          end
          lsas << lsa
        end
        @iface.send_update(lsas, unicast_destination) unless lsas.empty?
      end

      # An LSA we asked for arrived, or a newer one. Called from flooding.
      def request_satisfied(key)
        return unless @ls_request.delete(key)
        @lsr_outstanding.delete(key)
        if @ls_request.empty?
          @lsr_timer&.cancel
          loading_done if @state == :loading
        elsif @lsr_outstanding.empty?
          send_ls_request
        end
      end

      # ---- retransmission list and acks (RFC 2328 13.6, 13.7) ----

      # +lsa+ was just sent to this neighbor (flooding sends it right after)
      # and waits for an ack. Each entry is retransmitted RxmtInterval after
      # it last went out (RFC 2328 13.6).
      def add_retransmit(lsa)
        @retransmit[lsa.key] = lsa
        @rxmt_sent[lsa.key] = now
        @rxmt_timer ||= loop.every(1, :lsu_rxmt, start: false) { retransmit_lsas }
        @rxmt_timer.restart unless @rxmt_timer.active?
      end

      def remove_retransmit(key)
        lsa = @retransmit.delete(key)
        @rxmt_sent.delete(key)
        @rxmt_timer&.cancel if @retransmit.empty?
        lsa
      end

      def retransmitting?(key)
        @retransmit.key?(key)
      end

      def receive_ack(ack)
        return unless at_least?(:exchange)
        ack.headers.each do |h|
          lsa = @retransmit[h.key]
          next unless lsa
          if h.same_instance?(lsa)
            remove_retransmit(h.key)
          else
            instance.log(:debug, @iface, "ack from #{self} for another instance of #{h.id_string}")
          end
        end
      end

      def summary
        {
          router_id: Addr.to_s(@router_id), address: Addr.to_s(@address), interface: @iface.name,
          state: @state, priority: @priority, dr: Addr.to_s(@dr), bdr: Addr.to_s(@bdr),
          dead_in: dead_in&.ceil, role: @master.nil? ? nil : (master? ? :slave : :master),
          ls_request: @ls_request.size, retransmit: @retransmit.size, db_summary: @db_summary.size,
          uptime: (now - @last_change).floor, state_changes: @state_changes
        }
      end

      private

      def change(new_state, event)
        old = @state
        return if old == new_state
        @state = new_state
        @last_change = now
        @state_changes += 1
        instance.log(:info, @iface, "neighbor #{self}: #{old} -> #{new_state} (#{event})")
        instance.neighbor_changed(self, old, new_state)
        crossed_two_way = (RANK[old] >= RANK[:two_way]) != (RANK[new_state] >= RANK[:two_way])
        @iface.neighbor_change if crossed_two_way
      end

      def start_exstart(event)
        clear_lists
        # RFC 2328 10.3: increment the DD sequence number, or pick a unique
        # value the first time.
        @dd_seq = ((@dd_seq || instance.random.rand(0x8000_0000)) + 1) & 0xffff_ffff
        @master = true
        change(:exstart, event)
        send_dd(Wire::DD_INIT | Wire::DD_MORE | Wire::DD_MASTER, [])
        @dd_timer ||= loop.every(@iface.rxmt_interval, :dd_rxmt, start: false) { resend_last_dd }
        @dd_timer.restart
      end

      def dd_exstart(dd)
        mine = instance.router_id
        if dd.init? && dd.more? && dd.master? && dd.headers.empty? && @router_id > mine
          # The neighbor is master. Take its sequence number and answer.
          @master = false
          @dd_seq = dd.seq
          @options = dd.options
          @dd_timer&.cancel
          negotiation_done
          @last_rcvd_dd = [dd.flags, dd.options, dd.seq]
          send_dd_page(dd.seq)
        elsif !dd.init? && !dd.master? && dd.seq == @dd_seq && @router_id < mine
          # We are master and this is the slave's first answer.
          @master = true
          @options = dd.options
          negotiation_done
          accept_dd(dd)
        end
        # Anything else: ignore it, the master retransmits.
      end

      def dd_exchange(dd)
        if duplicate_dd?(dd)
          resend_last_dd unless master?
          return
        end
        return seq_number_mismatch('MS bit') if dd.master? == master?
        return seq_number_mismatch('I bit set') if dd.init?
        return seq_number_mismatch('options changed') if dd.options != @options
        expected = master? ? @dd_seq : (@dd_seq + 1) & 0xffff_ffff
        return seq_number_mismatch("sequence #{dd.seq}, expected #{expected}") unless dd.seq == expected
        accept_dd(dd)
      end

      def duplicate_dd?(dd)
        @last_rcvd_dd == [dd.flags, dd.options, dd.seq]
      end

      # RFC 2328 10.8 "Next". +dd+ passed every check.
      def accept_dd(dd)
        @last_rcvd_dd = [dd.flags, dd.options, dd.seq]
        dd.headers.each do |h|
          unless SUPPORTED_TYPES.include?(h.type)
            seq_number_mismatch("unsupported LSA type #{h.type}")
            return
          end
          ours = instance.lsdb_for(h.type, @iface.area)&.[](h.key)
          @ls_request[h.key] = h if ours.nil? || h.newer_than?(ours)
        end

        if master?
          # The slave acknowledged our last DD.
          @dd_seq = (@dd_seq + 1) & 0xffff_ffff
          if !@last_sent_more && !dd.more?
            @dd_timer&.cancel
            exchange_done
          else
            send_dd_page(@dd_seq)
          end
        else
          @dd_seq = dd.seq
          send_dd_page(@dd_seq)
          exchange_done if !dd.more? && !@last_sent_more
        end
        send_ls_request if @lsr_outstanding.empty? && !@ls_request.empty?
      end

      def negotiation_done
        @db_summary = []
        instance.lsdbs_for(@iface.area).each do |db|
          db.each do |lsa|
            if lsa.max_age?
              add_retransmit(lsa) # RFC 2328 10.3: MaxAge LSAs go here instead
            else
              @db_summary << lsa.header
            end
          end
        end
        change(:exchange, 'NegotiationDone')
      end

      def exchange_done
        @dd_timer&.cancel
        if @ls_request.empty?
          change(:full, 'ExchangeDone')
        else
          change(:loading, 'ExchangeDone')
          send_ls_request if @lsr_outstanding.empty?
        end
      end

      def loading_done
        change(:full, 'LoadingDone')
      end

      def send_dd_page(seq)
        room = @iface.max_body - 8
        count = [room / LsaHeader::SIZE, @db_summary.size].min
        page = @db_summary.shift(count)
        more = !@db_summary.empty?
        flags = (more ? Wire::DD_MORE : 0) | (master? ? Wire::DD_MASTER : 0)
        send_dd(flags, page, seq)
        @dd_timer&.restart if master?
      end

      def send_dd(flags, headers, seq = @dd_seq)
        dd = Wire::DatabaseDescription.new(mtu: @iface.mtu, options: @iface.options, flags: flags,
                                           seq: seq, headers: headers)
        @last_sent_dd = dd
        # The initial DD carries no summary, so more is still to come.
        @last_sent_more = (flags & (Wire::DD_INIT | Wire::DD_MORE)).positive?
        @iface.send_packet(dd, unicast_destination)
      end

      def resend_last_dd
        @iface.send_packet(@last_sent_dd, unicast_destination) if @last_sent_dd
      end

      def send_ls_request
        room = @iface.max_body
        batch = []
        @ls_request.each_key do |key|
          break if (batch.size + 1) * 12 > room
          batch << key
        end
        return if batch.empty?
        @lsr_outstanding = batch
        @iface.send_packet(Wire::LinkStateRequest.new(requests: batch), unicast_destination)
        @lsr_timer ||= loop.every(@iface.rxmt_interval, :lsr_rxmt, start: false) { resend_ls_request }
        @lsr_timer.restart
      end

      def resend_ls_request
        @lsr_outstanding &= @ls_request.keys
        if @lsr_outstanding.empty?
          @lsr_timer&.cancel
          send_ls_request unless @ls_request.empty?
        else
          @iface.send_packet(Wire::LinkStateRequest.new(requests: @lsr_outstanding), unicast_destination)
        end
      end

      # Resends the entries whose RxmtInterval is up, one update's worth
      # per run, oldest first. The rest wait for the next run.
      def retransmit_lsas
        due_by = now - @iface.rxmt_interval
        room = @iface.max_body - 4
        lsas = []
        @rxmt_sent.sort_by { |_, t| t }.each do |key, sent|
          break if sent > due_by
          lsa = @retransmit[key]
          # Send the database copy so the age is current.
          cur = instance.lsdb_for(key[0], @iface.area)&.[](key)
          lsa = cur if cur&.same_instance?(lsa)
          break if !lsas.empty? && lsas.sum(&:length) + lsa.length > room
          lsas << lsa
          @rxmt_sent[key] = now
        end
        @iface.send_update(lsas, unicast_destination) unless lsas.empty?
      end

      def clear_lists
        @db_summary = []
        @ls_request = {}
        @lsr_outstanding = []
        @retransmit.clear
        @rxmt_sent.clear
        @last_rcvd_dd = nil
        @last_sent_dd = nil
        [@dd_timer, @lsr_timer, @rxmt_timer].each { |t| t&.cancel }
      end
    end
  end
end
