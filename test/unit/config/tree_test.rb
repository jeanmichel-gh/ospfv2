# frozen_string_literal: true

require 'test/unit'
require 'ospfv2/config/tree'

class TestConfigTree < Test::Unit::TestCase
  include OSPFv2::Config

  def tree(*lines)
    Tree.parse(lines.join("\n"))
  end

  def test_set_with_abbreviations_and_canonical_values
    t = tree('set rout router-id 1.1.1.1', 'set prot ospf ar 0 int eth1 met 20', 'set protocols ospf area 1 interface eth2')
    assert_equal ['set routing-options router-id 1.1.1.1',
                  'set protocols ospf area 0.0.0.0 interface eth1 metric 20',
                  'set protocols ospf area 0.0.0.1 interface eth2'], t.to_set
  end

  def test_curly_display
    t = tree('set routing-options router-id 1.1.1.1',
             'set protocols ospf area 0 interface eth1 interface-type p2p',
             'set protocols ospf area 0 interface lo passive')
    assert_equal <<~CONF.chomp, t.to_curly
      routing-options {
          router-id 1.1.1.1;
      }
      protocols {
          ospf {
              area 0.0.0.0 {
                  interface eth1 {
                      interface-type p2p;
                  }
                  interface lo {
                      passive;
                  }
              }
          }
      }
    CONF
  end

  def test_errors_name_the_problem
    {
      'set protocols ospf area 0 interface eth1 metrik 5' => /unknown 'metrik' after 'protocols ospf area 0 interface eth1'/,
      'set protocols ospf area 0 interface eth1 p 5' => /'p' is ambiguous .*: priority, passive/,
      'set protocols ospf area 0 interface eth1 metric 0' => /within range \(1\.\.65535\)/,
      'set protocols ospf area 0 interface eth1 metric' => /missing <1\.\.65535>/,
      'set protocols ospf area 0 interface eth1 passive yes' => /unknown 'yes'/,
      'set protocols ospf area 300.0.0.0' => /invalid area/,
      'set routing-options router-id 1.2.3' => /invalid IPv4 address/,
      'set protocols ospf area 0 interface eth1 authentication md5 1' => /missing 'key'/,
      'set protocols ospf area 0 interface eth1 authentication md5 1 key 01234567890123456' => /longer than 16/,
      'set protocols ospf area 0 interface eth1 authentication simple-password 123456789' => /longer than 8/,
      'set protocols ospf area 0 interface eth1 interface-type nbma' => /not one of: broadcast, p2p/,
      'set protocols' => nil,
      'frob protocols' => /expected set or delete/
    }.each do |line, msg|
      t = Tree.new
      if msg
        e = assert_raise(Error, line) { t.apply(line) }
        assert_match(msg, e.message, line)
      else
        assert_nothing_raised(line) { t.apply(line) }
      end
    end
  end

  def test_a_failed_set_changes_nothing
    t = Tree.new
    assert_raise(Error) { t.set('protocols ospf area 0 interface eth2 hello-interval 0') }
    assert t.empty?
  end

  def test_delete
    t = tree('set protocols ospf area 0 interface eth1 metric 20',
             'set protocols ospf area 0 interface eth1 authentication md5 1 key a',
             'set protocols ospf area 0 interface eth1 authentication md5 2 key b',
             'set protocols ospf area 0 interface eth2 passive')
    t.delete('protocols ospf area 0 interface eth1 authentication md5 1')
    assert_includes t.to_set(hide: false).join("\n"), 'md5 2 key b'
    t.delete('protocols ospf area 0 interface eth1 authentication')
    t.delete('protocols ospf area 0 interface eth1 metric')
    # An emptied interface stays: "interface eth1;" runs OSPF with defaults.
    assert_equal ['set protocols ospf area 0.0.0.0 interface eth1',
                  'set protocols ospf area 0.0.0.0 interface eth2 passive'], t.to_set
    t.delete('protocols ospf area 0 interface eth2 passive')
    t.delete('protocols ospf area 0')
    assert t.empty?, 'empty containers go with the last thing in them'
    e = assert_raise(Error) { t.delete('protocols ospf') }
    assert_match(/statement not found/, e.message)
  end

  def test_delete_with_a_value_must_match_it
    t = tree('set protocols ospf area 0 interface eth1 metric 5', 'set protocols ospf area 0 interface eth1 passive')
    assert_raise(Error) { t.delete('protocols ospf area 0 interface eth1 metric 6') }
    assert_raise(Error) { t.delete('protocols ospf area 0 interface eth1 passive now') }
    assert_raise(Error) { t.delete('protocols ospf area 0 interface eth1 metric 5 extra') }
    t.delete('protocols ospf area 0 interface eth1 metric 5')
    assert_equal ['set protocols ospf area 0.0.0.0 interface eth1 passive'], t.to_set
  end

  def test_errors_never_show_secrets
    errors = Tree.new.load(%(set protocols ospf area 0 interface e authentication md5 1 key TOPSECRETTOPSECRETXX\n) +
                           %(set protocols ospf area 0 interface e authentication simple-password "a b c d e f"\n))
    assert_equal 2, errors.size
    assert_no_match(/TOPSECRET|a b c/, errors.join)
    assert_equal 'x key "<hidden>" y', Tree.hide_secrets('x key "sec ret" y')
  end

  def test_secrets_are_hidden_and_hidden_is_refused
    t = tree('set protocols ospf area 0 interface eth1 authentication hmac-sha-256 1 key "two words"')
    assert_match(/key "<hidden>"; ## SECRET-DATA/, t.to_curly)
    assert_match(/key "two words"/, t.to_set(hide: false).first)
    e = assert_raise(Error) { t.apply(t.to_set.first) }
    assert_match(/type the real secret/, e.message)
  end

  def test_unhidden_set_lines_load_back_identically
    t = tree('set routing-options router-id 1.1.1.1',
             'set protocols ospf area 0 interface eth1 authentication md5 1 key "a \"quoted\" \\\\ key"',
             'set protocols ospf area 0 interface eth1 dead-interval 40')
    assert_equal t, Tree.parse(t.to_set(hide: false).join("\n"))
  end

  def test_compare
    a = tree('set protocols ospf area 0 interface eth1', 'set protocols ospf area 0 interface eth2 metric 5')
    b = a.dup
    b.set('protocols ospf area 0 interface eth1 metric 7')
    b.delete('protocols ospf area 0 interface eth2')
    assert_equal ['- set protocols ospf area 0.0.0.0 interface eth2 metric 5',
                  '+ set protocols ospf area 0.0.0.0 interface eth1 metric 7'], a.compare(b)
    assert_empty a.compare(a.dup)
  end

  def test_split_quotes
    assert_equal ['set', 'a b', 'c"d', 'e'], Tree.split('set "a b" "c\"d" e')
    assert_raise(Error) { Tree.split('set "open') }
  end

  def test_load_reports_each_bad_line_and_keeps_the_good_ones
    t = Tree.new
    errors = t.load("set routing-options router-id 1.1.1.1\n# comment\n\nset bogus\nset routing-options router-id x\n")
    assert_equal 2, errors.size
    assert_match(/\Aline 4: /, errors[0])
    assert_match(/\Aline 5: /, errors[1])
    assert_equal ['set routing-options router-id 1.1.1.1'], t.to_set
  end

  def test_siblings_on_one_line
    t = Tree.new
    assert_empty t.load("set protocols ospf area 2 stub default-metric 10 no-summaries\n" \
                        'set protocols ospf area 0 interface eth1 metric 5 passive priority 0')
    assert_equal ['set protocols ospf area 0.0.0.2 stub default-metric 10',
                  'set protocols ospf area 0.0.0.2 stub no-summaries',
                  'set protocols ospf area 0.0.0.0 interface eth1 metric 5',
                  'set protocols ospf area 0.0.0.0 interface eth1 priority 0',
                  'set protocols ospf area 0.0.0.0 interface eth1 passive'], t.to_set
    before = t.to_set
    assert_match(/unknown 'bogus'/, t.load('set protocols ospf area 2 stub default-metric 20 bogus').join)
    assert_equal before, t.to_set, 'all or nothing'
  end
end
