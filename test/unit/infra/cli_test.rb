require 'test/unit'
require 'stringio'
require 'json'
require 'tmpdir'
require 'ospfv2/cli'

class TestCLI < Test::Unit::TestCase
  EXAMPLE = File.expand_path('../../../examples/grid.yml', __dir__)

  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    rc = OSPFv2::CLI.new(out: out, err: err).run(args)
    [rc, out.string, err.string]
  end

  def test_usage_and_version
    rc, out, = run_cli
    assert_equal 0, rc
    assert_match(/ospfv2 run TOPOLOGY.yml/, out)
    assert_match(/\A ?ospfv2 \d+\.\d+\.\d+/, run_cli('version')[1])
  end

  def test_unknown_command
    rc, _, err = run_cli('frobnicate')
    assert_equal 2, rc
    assert_match(/unknown command/, err)
  end

  def test_check
    rc, out, = run_cli('check', EXAMPLE)
    assert_equal 0, rc
    assert_match(/OK/, out)
    assert_match(/routers\s+19/, out)
    assert_match(/95 LSAs/, out)
  end

  def test_check_reports_errors
    Dir.mktmpdir do |d|
      f = File.join(d, 'bad.yml')
      File.write(f, "links: [[x, y]]\n")
      rc, _, err = run_cli('check', f)
      assert_equal 2, rc
      assert_match(/unknown router "x"/, err)
    end
    rc, _, err = run_cli('check', '/no/such.yml')
    assert_equal 2, rc
    assert_match(/no such file/, err)
  end

  def test_show_formats
    assert_match(/Extern\s+50.0.0.0/, run_cli('show', EXAMPLE)[1])
    rows = JSON.parse(run_cli('show', EXAMPLE, '-f', 'json', '-t', 'summary')[1])
    assert_equal 25, rows.size
    assert_match(/Netmask|mask/, run_cli('show', EXAMPLE, '-t', 'as_external', '-v')[1])
  end

  def test_export
    dot = run_cli('export', EXAMPLE)[1]
    assert_match(/\Agraph ospf \{/, dot)
    assert_match(/"abr1" -- "asbr1" \[label="50", style=dashed/, dot)
    h = JSON.parse(run_cli('export', EXAMPLE, '-f', 'json')[1])
    assert_equal 18, h['routers'].size
    assert_match(/simulator:/, run_cli('export', EXAMPLE, '-f', 'yaml')[1])
  end

  def test_init_output_is_a_valid_topology
    yaml = run_cli('init', '--grid', '2x3')[1]
    Dir.mktmpdir do |d|
      f = File.join(d, 'lab.yml')
      File.write(f, yaml)
      rc, out, = run_cli('check', f)
      assert_equal 0, rc
      assert_match(/routers\s+8/, out) # 6 grid + edge + sim
    end
  end

  def test_legacy_flags_map_to_a_topology
    o = OptParse.parse(%w[-i 10.0.0.5/24 -r 9.9.9.9 -a 0.0.0.3 -g 3x2 -S 4 -E 5 --hello-interval 5 --network p2p])
    t = OSPFv2::CLI.new.legacy_topology(o)
    s = t.settings
    assert_equal '10.0.0.5/24', s.interface
    assert_equal IPAddr.new('9.9.9.9').to_i, s.router_id
    assert_equal 3, s.area
    assert_equal 5, s.hello_interval
    assert_equal 20, s.dead_interval
    assert_equal :p2p, s.network_type
    assert_equal 6 + 1, t.counts[:routers]
    assert_equal 4, t.counts[:summaries]
    assert_equal 5, t.counts[:externals]
    assert t.links.any? { |l| l.from == 'sim' && l.to == 'r1c1' }
  end
end
