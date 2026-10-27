# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'ospfv2/daemon'

# Virtual links from the configuration.
#
#   ospfd (areas 1 and 2) -- area 1 -- peer (ABR, areas 0 and 1)
#
# ospfd's area 2 reaches the backbone only over a virtual link to the peer.
class TestDaemonVirtualLink < Test::Unit::TestCase
  include OSPFv2
  A = ->(s) { Core::Addr.to_i(s) }

  BASE = ['set routing-options router-id 1.1.1.1',
          'set protocols ospf area 1 interface eth1',
          'set protocols ospf area 2 interface lo passive'].freeze
  VL = 'set protocols ospf area 0 virtual-link neighbor-id 2.2.2.2 transit-area 1'

  def setup
    @dir = Dir.mktmpdir('ospfd-vl')
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e })
    hub = Transport::Hub.new
    system = Daemon::FakeSystem.new
    system.set('eth1', '10.0.0.1/24')
    system.set('lo', '1.1.1.1/32')
    @peer = Core::Instance.new(router_id: '2.2.2.2', loop: @loop)
    @peer.add_interface(name: 'e0', address: '10.0.0.2/24', area: 1, transport: Transport::Loopback.new(hub, '10.0.0.2'))
    @peer.add_interface(name: 'lo', address: '2.2.2.2/32', area: 0, passive: true)
    @peer.add_virtual_link(neighbor: '1.1.1.1', transit_area: 1)
    @peer.start
    @d = Daemon.new(config_path: File.join(@dir, 'ospfd.conf'), loop: @loop, system: system,
                    transport: ->(_n, ip) { Transport::Loopback.new(hub, ip) })
    @d.start
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def commit!(*lines)
    assert_empty @d.configure(lines)
    r = @d.commit
    assert r[:ok], r[:errors].join("\n")
  end

  def test_a_configured_virtual_link
    commit!(*BASE, VL, 'set protocols ospf area 0 virtual-link neighbor-id 2.2.2.2 hello-interval 5',
            'set protocols ospf area 0 virtual-link neighbor-id 2.2.2.2 dead-interval 20')
    vl = @d.instance.virtual_links[A['2.2.2.2']]
    assert_equal [5, 20], [vl.hello_interval, vl.dead_interval]
    # Back to the peer's timers: a changed setting replaces the link.
    commit!('delete protocols ospf area 0 virtual-link neighbor-id 2.2.2.2 hello-interval',
            'delete protocols ospf area 0 virtual-link neighbor-id 2.2.2.2 dead-interval')
    refute_same vl, (vl = @d.instance.virtual_links[A['2.2.2.2']])
    assert @loop.run_until(180) { vl.full_neighbors.any? && @peer.routes.key?([A['1.1.1.1'], 32]) }
    assert_equal :inter, @peer.routes[[A['1.1.1.1'], 32]].path_type, 'area 2 summarized over the virtual link'
    assert vl.full_neighbors.any?
    assert(@d.views.interfaces.any? { |i| i[:name] == 'vl-2.2.2.2' && i[:type] == :virtual })
    commit!('set protocols ospf area 0 virtual-link neighbor-id 2.2.2.2 authentication md5 1 key secret')
    assert_same vl, @d.instance.virtual_links[A['2.2.2.2']], 'a key applies in place, no restart'
    assert_match(/md5/i, vl.auth.to_s)
    commit!('delete protocols ospf area 0 virtual-link')
    assert_empty @d.instance.virtual_links
  end

  def test_configuration_errors
    errs = lambda do |*lines|
      @d.configure(lines)
      r = @d.commit
      @d.discard
      r[:errors].join("\n")
    end
    assert_match(/belong under area 0\.0\.0\.0/, errs.call(*BASE, 'set protocols ospf area 1 virtual-link neighbor-id 2.2.2.2 transit-area 2'))
    assert_match(/transit-area is required/, errs.call(*BASE, 'set protocols ospf area 0 virtual-link neighbor-id 2.2.2.2 hello-interval 5'))
    assert_match(/cannot be the backbone/, errs.call(*BASE, 'set protocols ospf area 0 virtual-link neighbor-id 2.2.2.2 transit-area 0'))
    assert_match(/is a stub; virtual links cannot cross it/,
                 errs.call(*BASE, 'set protocols ospf area 1 stub', VL))
  end
end
