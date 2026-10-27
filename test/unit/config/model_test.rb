# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/config/model'
require 'ospfv2/core/auth'

class TestConfigModel < Test::Unit::TestCase
  include OSPFv2::Config

  def model(*lines)
    Model.new(Tree.parse((['set routing-options router-id 1.1.1.1'] + lines).join("\n")))
  end

  def errors(*lines)
    Model.new(Tree.parse(lines.join("\n")))
    flunk 'expected errors'
  rescue Error => e
    e.message.lines.map(&:chomp)
  end

  def test_interface_options
    m = model('set protocols ospf area 0 interface eth1 interface-type p2p',
              'set protocols ospf area 0 interface eth1 metric 20',
              'set protocols ospf area 0 interface eth1 priority 0',
              'set protocols ospf area 0 interface eth1 hello-interval 5',
              'set protocols ospf area 0 interface eth1 dead-interval 20',
              'set protocols ospf area 0 interface eth1 retransmit-interval 3',
              'set protocols ospf area 0 interface eth1 transit-delay 2',
              'set protocols ospf area 0 interface eth1 mtu 9000',
              'set protocols ospf area 0 interface eth1 mtu-ignore',
              'set protocols ospf area 1 interface lo passive')
    assert_equal '1.1.1.1', m.router_id
    assert_equal({ area: '0.0.0.0', type: :p2p, cost: 20, priority: 0, hello_interval: 5, dead_interval: 20,
                   rxmt_interval: 3, transmit_delay: 2, mtu: 9000, mtu_ignore: true }, m.interfaces['eth1'])
    assert_equal({ area: '0.0.0.1', type: :broadcast, passive: true }, m.interfaces['lo'])
  end

  def test_authentication_specs_build
    m = model('set protocols ospf area 0 interface a authentication simple-password pw',
              'set protocols ospf area 0 interface b authentication md5 1 key k1',
              'set protocols ospf area 0 interface b authentication hmac-sha-256 2 key k2',
              'set protocols ospf area 0 interface b authentication send-key 1')
    assert_equal({ type: :simple, password: 'pw' }, m.interfaces['a'][:auth])
    b = m.interfaces['b'][:auth]
    assert_equal({ type: :crypto, send_key: 1,
                   keys: [{ id: 1, algorithm: :md5, secret: 'k1' }, { id: 2, algorithm: :hmac_sha256, secret: 'k2' }] }, b)
    auth = OSPFv2::Core::Auth.build(b)
    assert_equal 1, auth.send_key.id
  end

  def test_errors_are_collected
    errs = errors('set protocols ospf area 0 interface eth1',
                  'set protocols ospf area 1 interface eth1',
                  'set protocols ospf area 0 interface eth2 hello-interval 10',
                  'set protocols ospf area 0 interface eth2 dead-interval 10',
                  'set protocols ospf area 0 interface eth3 authentication simple-password pw',
                  'set protocols ospf area 0 interface eth3 authentication md5 1 key k',
                  'set protocols ospf area 0 interface eth4 authentication md5 1 key k',
                  'set protocols ospf area 0 interface eth4 authentication hmac-sha-1 1 key k',
                  'set protocols ospf area 0 interface eth5 authentication md5 1 key k',
                  'set protocols ospf area 0 interface eth5 authentication send-key 9')
    assert_equal 6, errs.size, errs.join("\n")
    assert_match(/router-id is required/, errs[0])
    assert_match(/eth1 is in area 0.0.0.0 and area 0.0.0.1/, errs.join)
    assert_match(/dead-interval 10 must be above hello-interval 10/, errs.join)
    assert_match(/eth3: use either simple-password or keys/, errs.join)
    assert_match(/eth4: key id 1 used by two algorithms/, errs.join)
    assert_match(/eth5: send-key 9 is not a configured key/, errs.join)
  end

  def test_dead_interval_is_checked_against_the_default_hello
    errs = errors('set routing-options router-id 1.1.1.1', 'set protocols ospf area 0 interface eth1 dead-interval 5')
    assert_equal ['interface eth1: dead-interval 5 must be above hello-interval 10'], errs
    require 'ospfv2/core'
    assert_equal OSPFv2::Core::Interface::DEFAULTS[:hello_interval], Model::DEFAULT_HELLO
  end

  def test_disabled_interfaces_and_warnings
    m = model('set protocols ospf area 0 interface eth1 disable')
    assert_empty m.interfaces
    assert_equal ['interface eth1 is disabled', 'no OSPF interfaces configured'], m.warnings
    assert_equal ['no OSPF interfaces configured'], model.warnings
  end

  def test_stub_areas
    m = model('set protocols ospf area 1 interface eth1', 'set protocols ospf area 1 stub',
              'set protocols ospf area 2 interface eth2', 'set protocols ospf area 2 stub default-metric 5',
              'set protocols ospf area 2 stub no-summaries')
    assert_equal({ '0.0.0.1' => { stub: { default_metric: nil, no_summaries: false } },
                   '0.0.0.2' => { stub: { default_metric: 5, no_summaries: true } } }, m.areas)
    assert_match(/backbone and cannot be a stub/, errors('set routing-options router-id 1.1.1.1',
                                                         'set protocols ospf area 0 stub').join)
  end
end
