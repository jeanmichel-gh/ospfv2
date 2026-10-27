# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/config/model'

# Export policies: policy-options policy-statement, Junos style.
class TestConfigPolicy < Test::Unit::TestCase
  include OSPFv2::Config

  BASE = ['set routing-options router-id 1.1.1.1', 'set protocols ospf export EXP'].freeze

  def policy(*terms)
    lines = terms.map { |t| "set policy-options policy-statement EXP #{t}" }
    Model.new(Tree.parse((BASE + lines).join("\n"))).export
  end

  def route(prefix, protocol = :static)
    ip, len = prefix.split('/')
    { protocol: protocol, prefix: ip.split('.').map(&:to_i).inject(0) { |a, o| (a << 8) | o }, prefix_len: len.to_i }
  end

  def test_route_filters
    p = policy('term a from route-filter 10.0.0.0/8 exact', 'term a then accept',
               'term b from route-filter 172.16.0.0/12 orlonger', 'term b then accept',
               'term c from route-filter 192.168.0.0/16 longer', 'term c then accept',
               'term d from route-filter 198.18.0.0/15 upto /24', 'term d then accept')
    yes = %w[10.0.0.0/8 172.16.0.0/12 172.20.1.0/24 192.168.1.0/24 198.18.0.0/15 198.19.5.0/24]
    no = %w[10.1.0.0/16 172.32.0.0/16 192.168.0.0/16 198.18.0.0/25 11.0.0.0/8]
    yes.each { |x| assert p.evaluate(route(x)), x }
    no.each { |x| assert_nil p.evaluate(route(x)), x }
  end

  def test_actions_defaults_and_order
    p = policy('term a from route-filter 10.0.0.0/8 orlonger', 'term a then tag 7',
               'term b from protocol static', 'term b then metric 5', 'term b then external type 1', 'term b then accept',
               'term c from protocol direct', 'term c then reject')
    assert_equal({ metric: 5, type: 1, tag: 7 }, p.evaluate(route('10.1.0.0/16')), 'term a sets the tag, b accepts')
    assert_equal({ metric: 5, type: 1, tag: 0 }, p.evaluate(route('20.0.0.0/8')))
    assert_nil p.evaluate(route('10.1.0.0/16', :direct)), 'rejected'
    assert_equal({ metric: 20, type: 2, tag: 0 }, policy('term a then accept').evaluate(route('1.0.0.0/8', :direct)),
                 'defaults: metric 20, type 2')
    assert_nil policy('term a from protocol static').evaluate(route('1.0.0.0/8')), 'nothing accepted: not exported'
  end

  def test_policy_errors_and_warnings
    m = Model.new(Tree.parse((BASE + ['set policy-options policy-statement EXP term a then metric 3']).join("\n")))
    assert_include m.warnings, 'policy-statement EXP accepts nothing'
    err = assert_raise(Error) { Model.new(Tree.parse(BASE.join("\n"))) }
    assert_match(/policy-statement EXP is not defined/, err.message)
    t = Tree.new
    assert_match(/not within range/, t.load('set policy-options policy-statement X term a then metric 16777215').join)
    assert_match(/invalid prefix/, t.load('set policy-options policy-statement X term a from route-filter 10.0.0.0 exact').join)
    assert_empty t.load('set policy-options policy-statement X term a from route-filter 10.9.9.9/16 exact')
    assert_match(%r{route-filter 10\.9\.0\.0/16}, t.to_set.join("\n"), 'host bits cleared')
  end

  # Junos: the longest filter containing the route decides.
  def test_the_longest_route_filter_decides
    p = policy('term a from route-filter 10.0.0.0/8 orlonger', 'term a from route-filter 10.1.0.0/16 exact',
               'term a then accept')
    assert p.evaluate(route('10.2.0.0/16'))
    assert p.evaluate(route('10.1.0.0/16'))
    assert_nil p.evaluate(route('10.1.1.0/24')), 'the /16 exact filter is the longest match and says no'
    p = policy('term a from route-filter 10.0.0.0/8 exact', 'term a from route-filter 10.0.0.0/8 longer',
               'term a then accept')
    assert p.evaluate(route('10.0.0.0/8'))
    assert p.evaluate(route('10.9.0.0/16')), 'several match types on one prefix'
    err = assert_raise(Error) do
      policy('term a from route-filter 10.0.0.0/16 upto /8', 'term a then accept')
    end
    assert_match(%r{upto /8 is shorter than the prefix /16}, err.message)
  end
end
