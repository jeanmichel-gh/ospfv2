# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/core'
require 'ospfv2/fib'
require 'support/core_lab'

# The FIB manager with SR-MPLS (docs/design/sr-ospf.md, step 4, PR 6),
# over the in-memory kernel: label routes, and pushes on IP routes.
#
#   r1 ---- r2 ---- r3   point-to-point; SRGBs 16000, 17000, 18000;
#   idx 1   idx 2   idx 3 on the loopbacks. The manager installs r1's.
class TestFibSrManager < Test::Unit::TestCase
  include OSPFv2
  A = ->(s) { Core::Addr.to_i(s) }
  P2P = { type: :p2p }.freeze

  def setup
    @lab = CoreLab.new
    a = @lab.segment
    b = @lab.segment
    @r1 = @lab.router('1.1.1.1', [a, '10.0.12.1/30', P2P], [:passive, '1.1.1.1/32'])
    @r2 = @lab.router('2.2.2.2', [a, '10.0.12.2/30', P2P], [b, '10.0.23.1/30', P2P], [:passive, '2.2.2.2/32'])
    @r3 = @lab.router('3.3.3.3', [b, '10.0.23.2/30', P2P], [:passive, '3.3.3.3/32'])
    [@r1, @r2, @r3].each_with_index do |r, i|
      r.opaque = true
      r.segment_routing = { srgb: [16_000 + (1000 * i), 8_000], srlb: [15_000, 1_000], index: i + 1 }
    end
    @kernel = Fib::Memory.new
    # Reconcile far off, so a label change reaches the kernel by the
    # route listener alone.
    @fib = Fib::Manager.new(loop: @lab.loop, backend: @kernel, reconcile: 3600)
  end

  def converge
    @fib.attach(@r1)
    @lab.start
    assert @lab.run_until(120) { @kernel.labels.key?(16_003) && @r1.routes.key?([A['3.3.3.3'], 32]) }
    @lab.advance(10)
  end

  def labels_s = @kernel.dump_labels.map(&:to_s).sort
  def route(p) = @kernel.dump.find { _1.dest_s == p }

  def test_label_routes_and_pushes
    converge
    assert_equal ['label 15000 pop via 10.0.12.2 dev eth0', 'label 16002 pop via 10.0.12.2 dev eth0',
                  'label 16003 swap 17003 via 10.0.12.2 dev eth0'], labels_s
    assert_equal [['eth0', A['10.0.12.2'], 17_003]], route('3.3.3.3/32').next_hops, 'r3 through r2: index 3 in r2\'s block'
    assert_equal [['eth0', A['10.0.12.2'], nil]], route('2.2.2.2/32').next_hops, 'implicit null: nothing pushed'
    assert(@fib.label_status.all? { _1.state == :installed })
  end

  # The host takes no label routes: IP routes only, nothing pushed.
  def test_labels_off
    @fib.labels_on = false
    converge_without_labels
    assert_empty @kernel.dump_labels
    assert_equal [['eth0', A['10.0.12.2'], nil]], route('3.3.3.3/32').next_hops
  end

  def converge_without_labels
    @fib.attach(@r1)
    @lab.start
    assert @lab.run_until(120) { route('3.3.3.3/32') && @r1.sr_labels&.entries&.key?(16_003) }
    @lab.advance(10)
  end

  # r3 stops SR: no route changes, but r1's labels do, and the FIB follows.
  def test_a_label_change_without_a_route_change
    converge
    @lab.advance(OSPFv2::MinLSInterval)
    @r3.segment_routing = nil
    assert @lab.run_until(60) { !@kernel.labels.key?(16_003) }
    assert_equal [['eth0', A['10.0.12.2'], nil]], route('3.3.3.3/32').next_hops, 'the IP route stays, unlabelled'
  end

  # Label routes of ours from before a restart are held, then the stale
  # ones go once converged.
  def test_old_label_routes_are_held_then_removed
    @kernel.labels[19_999] = Fib::Label.new(19_999, [['eth0', A['10.0.12.2'], nil]])
    converge
    assert @lab.run_until(120) { !@kernel.labels.key?(19_999) }
    assert @kernel.labels.key?(16_003)
  end

  def test_reconcile_repairs_a_label
    converge
    @kernel.labels.delete(16_003)
    @fib.reconcile
    assert @kernel.labels.key?(16_003)
    assert_operator @fib.repairs, :>, 0
  end

  def test_detach_withdraws_labels
    converge
    @fib.detach
    assert_empty @kernel.dump_labels
  end
end
