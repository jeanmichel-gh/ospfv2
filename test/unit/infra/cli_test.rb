require 'test/unit'
require 'stringio'
require 'json'
require 'tmpdir'
require 'yaml'
require 'ospfv2/cli'
require 'ospfv2/config/tree'

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

  def test_lab_new_copies_the_template
    Dir.mktmpdir do |d|
      dir = File.join(d, 'my-lab')
      rc, out, = run_cli('lab', 'new', dir, '--no-git')
      assert_equal 0, rc
      assert_match(/lab created in #{Regexp.escape(dir)}/, out)
      assert_match(/export LAB=#{Regexp.escape(dir)}/, out)
      %w[lab.yml .gitignore tools/frr-start.sh sim/sim.yml peer/peer.yml frr/frr.conf frr/daemons frr/vtysh.conf ospfd/ospfd.conf].each do |f|
        assert File.file?(File.join(dir, f)), "missing #{f}"
      end
      refute File.exist?(File.join(dir, '.git'))
      assert_equal 0, run_cli('check', File.join(dir, 'sim/sim.yml'))[0]
    end
  end

  def test_lab_new_containerlab
    Dir.mktmpdir do |d|
      dir = File.join(d, 'ring')
      rc, out, = run_cli('lab', 'new', dir, '--no-git', '--containerlab')
      assert_equal 0, rc
      assert_match(/sudo containerlab deploy -t ospf-ring.clab.yml/, out)
      %w[ospf-ring.clab.yml .gitignore sim/sim.yml frr/frr.conf frr/daemons frr/vtysh.conf ospfd/ospfd.conf bird/bird.conf].each do |f|
        assert File.file?(File.join(dir, f)), "missing #{f}"
      end
      refute File.exist?(File.join(dir, 'lab.yml')), 'the topology is the lab'
      assert_equal 0, run_cli('check', File.join(dir, 'sim/sim.yml'))[0]
      topo = YAML.safe_load(File.read(File.join(dir, 'ospf-ring.clab.yml')))
      assert_equal %w[sim frr ospfd bird], topo['topology']['nodes'].keys
      assert_equal 4, topo['topology']['links'].size
      assert_equal [], OSPFv2::Config::Tree.new.load(File.read(File.join(dir, 'ospfd/ospfd.conf'))), 'ospfd.conf loads'
    end
  end

  def test_lab_new_leaves_out_what_the_routers_wrote_in_the_template
    Dir.mktmpdir do |d|
      src = File.join(d, 'template')
      FileUtils.mkdir_p(File.join(src, 'frr'))
      File.write(File.join(src, '.gitignore'), "# routers' files\n*.sav\n*.rollback.*\n")
      File.write(File.join(src, 'lab.yml'), 'nodes: {}')
      File.write(File.join(src, 'frr/frr.conf'), 'hostname frr')
      File.write(File.join(src, 'frr/frr.conf.sav'), 'old')
      File.write(File.join(src, 'frr/x.conf.rollback.1'), 'old')
      File.write(File.join(src, 'frr/unreadable.sav'), 'root only')
      File.chmod(0o000, File.join(src, 'frr/unreadable.sav'))
      dst = File.join(d, 'lab')
      OSPFv2::CLI.copy_lab(src, dst)
      assert_equal %w[.gitignore frr frr/frr.conf lab.yml], Dir.glob('**/*', File::FNM_DOTMATCH, base: dst).reject { |f| File.basename(f) == '.' }.sort
    end
  end

  def test_lab_new_makes_a_git_repository
    omit('git not installed') unless system('git', '--version', out: File::NULL, err: File::NULL)
    Dir.mktmpdir do |d|
      dir = File.join(d, 'lab')
      rc, out, = run_cli('lab', 'new', dir)
      assert_equal 0, rc
      assert_match(/^git: repository created/, out)
      assert File.directory?(File.join(dir, '.git'))
      env = { 'GIT_AUTHOR_NAME' => nil, 'GIT_AUTHOR_EMAIL' => nil, 'GIT_COMMITTER_NAME' => nil, 'GIT_COMMITTER_EMAIL' => nil }
      assert_equal "lab <lab@configs>\n", IO.popen(env, ['git', '-C', dir, 'log', '-1', '--format=%an <%ae>'], &:read)
    end
  end

  def test_lab_new_refuses_a_folder_in_use
    Dir.mktmpdir do |d|
      File.write(File.join(d, 'keep.txt'), 'mine')
      rc, _, err = run_cli('lab', 'new', d)
      assert_equal 2, rc
      assert_match(/exists and is not empty/, err)
      assert_equal ['keep.txt'], Dir.children(d)
    end
    assert_equal 0, Dir.mktmpdir { |d| run_cli('lab', 'new', d, '--no-git')[0] }
  end

  def test_lab_new_says_why_it_cannot_make_the_folder
    omit('root writes anywhere') if Process.uid.zero?
    Dir.mktmpdir do |d|
      File.chmod(0o555, d)
      rc, _, err = run_cli('lab', 'new', File.join(d, 'lab'))
      assert_equal 2, rc
      assert_match(/cannot make the lab folder.*not writable: sudo chown/, err)
    ensure
      File.chmod(0o755, d)
    end
  end

  # A pcap file with two OSPF frames and one ARP frame, dissected one JSON
  # line each.
  def test_capture_reads_a_pcap_file
    require 'ospfv2/core/wire'
    w = OSPFv2::Core::Wire
    hello = w.encode(w::Hello.new(netmask: 0xffffff00, hello_interval: 2, options: 2, priority: 1, dead_interval: 8,
                                  dr: 0, bdr: 0, neighbors: []), router_id: 0x02020202, area_id: 0)
    ip = [0x45, 0, 20 + hello.bytesize, 0, 0, 1, 89, 0, 0x0a630014, 0xe0000005].pack('CCnnnCCnNN')
    s = ip.unpack('n*').sum
    s = (s & 0xffff) + (s >> 16) while s > 0xffff
    ip[10, 2] = [~s & 0xffff].pack('n')
    eth = ['01005e000005', '0242ac110002'].pack('H12H12') + [0x0800].pack('n')
    frames = [eth + ip + hello, ['ffffffffffff0242ac1100020806'].pack('H*') + ("\0" * 46), eth + ip + hello]
    Dir.mktmpdir do |d|
      path = File.join(d, 'cap.pcap')
      File.open(path, 'wb') do |f|
        f.write([0xa1b2c3d4, 2, 4, 0, 0, 65_535, 1].pack('VvvVVVV'))
        frames.each_with_index { |fr, i| f.write([1_793_200_000 + i, 250_000, fr.bytesize, fr.bytesize].pack('VVVV') + fr) }
      end
      rc, out, = run_cli('capture', '-r', path, '-c', '2')
      assert_equal 0, rc
      lines = out.lines.map { JSON.parse(_1) }
      assert_equal({ 'interface' => nil, 'file' => path, 'link' => 'ethernet', 'filter' => 'ip proto 89' }, lines[0]['capture'])
      p1, p2 = lines[1]['packet'], lines[2]['packet']
      assert_equal [1, 'Hello 10.99.0.20 > 224.0.0.5, DR 0.0.0.0, 0 neighbors', []], p1.values_at('seq', 'summary', 'errors')
      assert_equal '2026-10-28T15:06:40.250000Z', p1['time']
      assert_equal 'not OSPF', p2['summary']
      assert_equal 3, lines.size, '-c 2 stops after two packets'
      File.write(path, 'junk' * 6)
      rc, out, = run_cli('capture', '-r', path)
      assert_equal [1, 'not a pcap stream'], [rc, JSON.parse(out)['error'][0, 17]]
    end
  end

  def test_lab_needs_a_subcommand_and_a_folder
    assert_match(/lab new DIR/, run_cli('lab')[2])
    assert_match(/lab new needs a folder/, run_cli('lab', 'new')[2])
  end

  def test_lab_template_files_are_valid
    lab = OSPFv2::CLI::LAB_TEMPLATE
    %w[sim/sim.yml peer/peer.yml].each { |f| assert_equal 0, run_cli('check', File.join(lab, f))[0], f }
    nodes = YAML.safe_load(File.read(File.join(lab, 'lab.yml')))['nodes']
    nodes.each { |n| assert File.file?(File.join(lab, n['config'])), "#{n['name']}: #{n['config']}" }
  end
end
