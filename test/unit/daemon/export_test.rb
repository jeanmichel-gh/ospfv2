# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'ospfv2/daemon'

# protocols ospf export: host networks and static routes advertised as
# AS externals, chosen by a policy.
class TestDaemonExport < Test::Unit::TestCase
  include OSPFv2

  BASE = ['set routing-options router-id 1.1.1.1',
          'set protocols ospf area 0 interface eth1'].freeze

  POLICY = ['set policy-options policy-statement EXP term statics from protocol static',
            'set policy-options policy-statement EXP term statics then metric 7',
            'set policy-options policy-statement EXP term statics then tag 9',
            'set policy-options policy-statement EXP term statics then accept',
            'set policy-options policy-statement EXP term lan from protocol direct',
            'set policy-options policy-statement EXP term lan from route-filter 192.0.2.0/24 exact',
            'set policy-options policy-statement EXP term lan then external type 1',
            'set policy-options policy-statement EXP term lan then accept',
            'set protocols ospf export EXP'].freeze

  A = ->(s) { Core::Addr.to_i(s) }

  def setup
    @dir = Dir.mktmpdir('ospfd-export')
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e })
    hub = Transport::Hub.new
    @system = Daemon::FakeSystem.new
    @system.set('eth1', '10.0.0.1/24')
    @system.set('eth2', '192.0.2.1/24')      # not running OSPF
    @system.set('eth3', '203.0.113.1/24')    # neither
    @system.statics = [[A['198.18.0.0'], 15]]
    @peer = Core::Instance.new(router_id: '2.2.2.2', loop: @loop)
    @peer.add_interface(name: 'e0', address: '10.0.0.2/24', transport: Transport::Loopback.new(hub, '10.0.0.2'))
    @peer.start
    @d = Daemon.new(config_path: File.join(@dir, 'ospfd.conf'), loop: @loop, system: @system,
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

  def route(prefix)
    p, len = prefix.split('/')
    @peer.routes[[A[p], len.to_i]]
  end

  def test_the_policy_picks_what_is_advertised
    commit!(*BASE, *POLICY)
    assert @loop.run_until(120) { route('198.18.0.0/15') && route('192.0.2.0/24') }
    r = route('198.18.0.0/15')
    assert_equal [:ext2, 7, 9], [r.path_type, r.type2_cost, r.tag]
    r = route('192.0.2.0/24')
    assert_equal [:ext1, 30], [r.path_type, r.cost], 'LAN 10 + default metric 20'
    assert_nil route('203.0.113.0/24'), 'not in the policy'
    assert @d.views.overview[:asbr]
  end

  def test_new_static_routes_and_policy_changes_follow
    commit!(*BASE, *POLICY)
    assert @loop.run_until(120) { route('198.18.0.0/15') }
    @system.statics << [A['100.64.0.0'], 10]
    assert @loop.run_until(10) { route('100.64.0.0/10') }, 'picked up within the 5 s recheck'
    @system.statics.clear
    assert @loop.run_until(10) { route('100.64.0.0/10').nil? && route('198.18.0.0/15').nil? }
    commit!('delete protocols ospf export')
    assert @loop.run_until(30) { route('192.0.2.0/24').nil? }
    refute @d.views.overview[:asbr]
  end
end
