# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'stringio'
require 'ospfv2/daemon'
require 'ospfv2/daemon/api'
require 'ospfv2/command_line/shell'

# ospf-cli against a daemon in the same process, with a core peer, on a
# fake clock.
class TestCommandLineShell < Test::Unit::TestCase
  include OSPFv2

  def setup
    @dir = Dir.mktmpdir('ospf-cli')
    @loop = EventLoop.new(clock: Clock::Fake.new, on_error: ->(e) { raise e })
    hub = Transport::Hub.new
    system = Daemon::FakeSystem.new
    system.set('eth1', '10.0.0.1/24')
    system.set('lo', '1.1.1.1/32')
    @daemon = Daemon.new(config_path: File.join(@dir, 'ospfd.conf'), loop: @loop, system: system,
                         transport: ->(_n, ip) { Transport::Loopback.new(hub, ip) })
    @daemon.start
    @peer = Core::Instance.new(router_id: '2.2.2.2', loop: @loop)
    @peer.add_interface(name: 'e0', address: '10.0.0.2/24', transport: Transport::Loopback.new(hub, '10.0.0.2'))
    @peer.start
    @sh = CommandLine::Shell.new(CommandLine::LocalClient.new(Daemon::Api.new(@daemon, path: '/unused')))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_lines(*lines)
    lines.map { |l| @sh.execute(l) }
  end

  def configured
    out = run_lines('configure', 'set routing-options router-id 1.1.1.1', 'set protocols ospf area 0 interface eth1',
                    'set protocols ospf area 0 interface lo passive', 'commit', 'exit')
    assert_equal 'commit complete', out[4]
    @loop.run_until(120) { @peer.neighbors.first&.full? }
    @loop.advance(5)
  end

  def test_configuration_mode
    assert_equal 'Entering configuration mode', @sh.execute('configure')
    assert_equal :configure, @sh.mode
    assert_equal 'ospf# ', @sh.prompt
    assert_equal '', @sh.execute('set routing-options router-id 1.1.1.1')
    assert_match(/error: syntax error, unknown 'metrik'/, @sh.execute('set protocols ospf area 0 interface eth1 metrik 5'))
    assert_equal '', @sh.execute('set prot ospf ar 0 int eth1 met 20')
    assert_equal "+ set routing-options router-id 1.1.1.1\n+ set protocols ospf area 0.0.0.0 interface eth1 metric 20",
                 @sh.execute('show | compare')
    assert_equal @sh.execute('show | compare'), @sh.execute('compare')
    assert_match(/metric 20;/, @sh.execute('show'))
    assert_equal 'configuration check succeeds', @sh.execute('commit check')
    assert_equal 'commit complete', @sh.execute('commit comment metric for eth1')
    assert_equal '[no changes]', @sh.execute('compare')
    assert_match(/metric for eth1/, @sh.execute('history'))
    assert_equal '', @sh.execute('delete protocols ospf area 0 interface eth1 metric')
    assert_match(/changed but not committed/, @sh.execute('exit'))
    assert_equal :operational, @sh.mode
    assert_match(/Entering configuration mode\nThe configuration has been changed/, @sh.execute('configure'))
    assert_equal 'Uncommitted changes discarded', @sh.execute('discard')
    assert_equal 'Exiting configuration mode', @sh.execute('end')
  end

  def test_commit_failure_is_reported
    run_lines('configure', 'set protocols ospf area 0 interface eth1')
    assert_equal "error: commit failed\n  routing-options router-id is required", @sh.execute('commit')
  end

  def test_rollback
    configured
    run_lines('configure', 'set protocols ospf area 0 interface eth1 metric 9', 'commit')
    assert_match(/rollback 1 loaded/, @sh.execute('rollback 1'))
    assert_equal '- set protocols ospf area 0.0.0.0 interface eth1 metric 9', @sh.execute('compare')
    assert_match(/error: syntax error, unknown 'x' after 'rollback'/, @sh.execute('rollback x'))
  end

  def test_commit_takes_only_check_or_a_comment
    run_lines('configure', 'set routing-options router-id 1.1.1.1')
    assert_match(/error: syntax error, unknown 'chekc' after 'commit'/, @sh.execute('commit chekc'))
    assert_match(/error: syntax error, unknown 'extra'/, @sh.execute('commit check extra'))
    assert @daemon.candidate_changed?, 'nothing was committed'
    assert_match(/commit complete\z/, @sh.execute('commit comment two words | here'))
    assert_equal 'two words', @daemon.commit_history.first[:comment], 'a pipe after a comment is cut off'
  end

  def test_bad_input_never_crashes_the_shell
    configured
    ['show ospf events | last -1', 'show ospf events | last 99999999999999999999', 'show ospf events | last x',
     'show ospf neighbor |', 'show ospf neighbor | | count', '"', 'show "ospf', '| count'].each do |line|
      out = @sh.execute(line)
      assert_match(/\Aerror: /, out, line)
    end
    assert_equal 3, @sh.execute('show ospf events | last 3').lines.size
  end

  def test_pipes_inside_quotes_are_text
    @sh.execute('configure')
    assert_equal '', @sh.execute('set protocols ospf area 0 interface eth1 authentication simple-password "a|b"')
    assert_match(/simple-password "<hidden>"/, @sh.execute('show | display set'))
  end

  def test_run_takes_operational_commands_only
    @sh.execute('configure')
    assert_match(/error: run takes show and clear commands/, @sh.execute('run exit'))
    assert_match(/error: run takes show and clear commands/, @sh.execute('run configure'))
    assert_equal :configure, @sh.mode
    assert_match(/not configured/, @sh.execute('run show ospf overview'))
  end

  def test_junos_and_ios_show_commands
    configured
    nbr = @sh.execute('show ospf neighbor')
    assert_match(/\AAddress\s+Interface\s+State\s+ID\s+Pri\s+Dead\n10\.0\.0\.2\s+eth1\s+Full\s+2\.2\.2\.2\s+1\s+\d+\z/, nbr)
    ios = @sh.execute('show ip ospf neighbor')
    assert_match(/\ANeighbor ID\s+Pri\s+State\s+Dead Time\s+Address\s+Interface\n2\.2\.2\.2\s+1\s+FULL\/DR\s+00:00:\d\d\s+10\.0\.0\.2\s+eth1\z/, ios)
    assert_equal ios, @sh.execute('sh ip os nei'), 'unique prefixes work'
    assert_match(/eth1\s+BDR\s+0\.0\.0\.0\s+2\.2\.2\.2\s+1\.1\.1\.1\s+1/, @sh.execute('show ospf interface'))
    assert_match(/eth1\s+1\s+0\s+10\.0\.0\.1\/24\s+10\s+BDR\s+1\/1/, @sh.execute('show ip ospf interface brief'))
    assert_match(/Designated Router \(ID\) 2\.2\.2\.2, Interface address 10\.0\.0\.2/, @sh.execute('show ip ospf interface'))
    db = @sh.execute('show ospf database')
    assert_match(/OSPF database, Area 0\.0\.0\.0/, db)
    assert_match(/^Router  \*1\.1\.1\.1\s+1\.1\.1\.1\s+0x8000000\d/, db)
    assert_match(/^Network  10\.0\.0\.2\s+2\.2\.2\.2/, db)
    assert_match(/Router Link States \(Area 0\).*1\.1\.1\.1\s+1\.1\.1\.1\s+\d+\s+0x8000000\d 0x[0-9A-F]{6} 2/m,
                 @sh.execute('show ip ospf database'))
    assert_match(/attached router 1\.1\.1\.1/, @sh.execute('show ospf database network detail'))
    assert_match(/Router ID: 1\.1\.1\.1/, @sh.execute('show ospf overview'))
    assert_match(/Routing Process "ospf 1" with ID 1\.1\.1\.1/, @sh.execute('show ip ospf'))
    assert_match(/hello\s+\d+\s+\d+/, @sh.execute('show ospf statistics'))
    assert_match(/neighbor 2\.2\.2\.2@10\.0\.0\.2: loading -> full/, @sh.execute('show ospf events'))
    assert_match(/hello\s+\d+\s+\d+/, @sh.execute('show ip ospf traffic'))
    assert_equal "1 neighbor cleared", @sh.execute('clear ospf neighbor 2.2.2.2')
  end

  def test_routes_and_spf
    @peer.add_interface(name: 'lo', address: '2.2.2.2/32', passive: true)
    configured
    @loop.run_until(30) { @daemon.instance.routes.size == 3 && !@daemon.instance.spf.pending? }
    junos = @sh.execute('show ospf route')
    assert_match(/^Topology default Route Table:/, junos)
    assert_match(%r{^2\.2\.2\.2/32\s+Intra\s+Network\s+IP\s+20 eth1\s+10\.0\.0\.2$}, junos)
    assert_match(%r{^10\.0\.0\.0/24\s+Intra\s+Network\s+IP\s+10 eth1$}, junos)
    assert_match(/area 0\.0\.0\.0, origin 2\.2\.2\.2/, @sh.execute('show ospf route detail'))
    frr = @sh.execute('show ip ospf route')
    assert_match(%r{^N    2\.2\.2\.2/32\s+\[20\] area: 0\.0\.0\.0\n\s+via 10\.0\.0\.2, eth1$}, frr)
    assert_match(%r{^N    10\.0\.0\.0/24\s+\[10\] area: 0\.0\.0\.0\n\s+directly attached to eth1$}, frr)
    rib = @sh.execute('show ip route ospf')
    assert_match(%r{^O        2\.2\.2\.2/32 \[110/20\] via 10\.0\.0\.2, eth1$}, rib)
    assert_no_match(/10\.0\.0\.0/, rib, 'connected networks are not OSPF routes')
    assert_equal rib, @sh.execute('sh ip ro os')
    junos_fib = @sh.execute('show route protocol ospf')
    assert_match(/\Ainet\.0: 1 destinations, 1 routes \(1 active/, junos_fib)
    assert_match(%r{^2\.2\.2\.2/32\s+\*\[OSPF/10\] metric 20\n\s+>  to 10\.0\.0\.2 via eth1$}, junos_fib)
    assert_match(/Kernel: 1 routes installed, protocol 89, table 254/, @sh.execute('show ospf overview'))
    log = @sh.execute('show ospf log')
    assert_match(/^SPF runs: [1-9]\d*, state: (short|long) wait/, log)
    assert_match(/initial 50 ms, short 200 ms, long 5000 ms, learn 500 ms, holddown 10000 ms/, log)
    assert_match(/\+\d+ ~\d+ -\d+\s+.*router 2\.2\.2\.2/, log)
    # The run that put 2.2.2.2/32 in: its route changes and kernel time.
    n = log.lines.grep(/^\s*\d+ .*\+[1-9]/).first.to_i
    run = @sh.execute("show ospf log run #{n}")
    assert_match(/\ASPF run #{n} at .*, (initial|short|long) delay$/, run)
    assert_match(/computed in \d+\.\d{3} ms, kernel in \d+\.\d ms/, run)
    assert_match(/^Route changes\n  \+/, run)
    assert_match(/No such SPF run/, @sh.execute('show ospf log run 99999'))
    stats = @sh.execute('show ip ospf statistics')
    assert_match(/SPF algorithm executed [1-9]\d* times/, stats)
    assert_match(/^00:00:0\d\s+\d+\s+\d+\s+\+\d+ ~\d+ -\d+\s+.*\bR\b/, stats)
    assert_match(/SPF: [1-9]\d* runs, last 00:00:0\d ago, 3 routes/, @sh.execute('show ospf overview'))
    assert_match(/SPF algorithm executed/, @sh.execute('show ip ospf'))
    json = JSON.parse(@sh.execute('show ospf route | display json'))
    assert_equal '2.2.2.2/32', json['routes'].find { |r| r['advr'] == '2.2.2.2' && r['prefix'].end_with?('/32') }['prefix']
  end

  def test_pipes
    configured
    assert_equal 'Count: 2 lines', @sh.execute('show ospf neighbor | count')
    assert_equal 1, @sh.execute('show ospf database | match ^Router.*2\.2\.2\.2').lines.size
    assert_no_match(/Network/, @sh.execute('show ospf database | except network'))
    json = JSON.parse(@sh.execute('show ospf neighbor | display json'))
    assert_equal 'full', json.first['state']
    assert_equal json, JSON.parse(@sh.execute('show ospf neighbor | json'))
    assert_match(/\Aset routing-options router-id 1\.1\.1\.1/, @sh.execute('show configuration | display set'))
    assert_equal 2, @sh.execute('show ospf events | last 2').lines.size
    assert_match(/error: unknown pipe 'frob'/, @sh.execute('show ospf neighbor | frob'))
    assert_match(/error: bad pattern/, @sh.execute('show ospf neighbor | match ('))
  end

  def test_errors
    assert_match(/error: incomplete command: show/, @sh.execute('show'))
    assert_match(/error: syntax error, unknown 'neighbour'/, @sh.execute('show ospf neighbour'))
    assert_match(/error: ambiguous 'c' : |error: ambiguous 'c': clear, configure/, @sh.execute('c'))
    assert_match(/not configured/, @sh.execute('show ospf overview'))
  end

  def test_question_mark_help
    help = @sh.execute('show ospf ?')
    assert_match(/\APossible completions:\n  neighbor\s+Neighbors\n/, help)
    assert_match(/  ospf\s+OSPF process/, @sh.execute('show ip o?'))
    assert_match(/<cr>/, @sh.execute('show ospf neighbor ?'))
    @sh.execute('configure')
    assert_match(/  routing-options\s+Protocol-independent/, @sh.execute('set ?'))
    assert_match(/  md5\s+Keyed MD5/, @sh.execute('set protocols ospf area 0 interface eth1 authentication ?'))
    assert_match(/<1\.\.65535>/, @sh.execute('set protocols ospf area 0 interface eth1 metric ?'))
    assert_match(/<area-id>/, @sh.execute('set protocols ospf area ?'))
  end

  def test_tab_completion
    assert_equal ['neighbor'], @sh.completions('show ospf ', 'ne')
    assert_equal %w[ospf], @sh.completions('sh ', 'o')
    assert_equal %w[clear configure], @sh.completions('', 'c')
    @sh.execute('configure')
    assert_equal ['passive'], @sh.completions('set protocols ospf area 0 interface eth1 ', 'pa')
    assert_equal ['protocols'], @sh.completions('set ', 'pro')
    assert_equal %w[commit compare], @sh.completions('', 'com').sort
  end

  def test_reads_commands_from_a_pipe
    configured
    out = StringIO.new
    @sh.interactive(input: StringIO.new("show ospf neighbor | count\nexit\nshow ospf overview\n"), output: out)
    assert_equal "Count: 2 lines\n", out.string, 'stops at exit'
  end

  def test_monitor_needs_the_socket
    assert_match(/monitor needs ospfd over its socket/, @sh.execute('monitor ospf events'))
  end

  def test_monitor_prints_events_and_filters
    api = Daemon::Api.new(@daemon, path: File.join(@dir, 's', 'ospfd.sock'))
    api.start
    out = StringIO.new
    sh = CommandLine::Shell.new(CommandLine::Client.new(api.path), output: out)
    sh.monitor_limit = 2
    t = Thread.new do
      sleep 0.02 until @daemon.events.subscribers == 1
      t0 = Time.utc(2026, 10, 28, 3, 18, 31)
      @daemon.events.publish(time: t0, level: :info, kind: :neighbor, interface: 'eth1', message: 'neighbor 2.2.2.2 up')
      @daemon.events.publish(time: t0, level: :warn, kind: :neighbor, interface: 'eth1', message: 'neighbor 3.3.3.3 lost')
      @daemon.events.publish(time: t0, level: :info, kind: :neighbor, interface: 'eth1', message: 'neighbor 2.2.2.2 full')
    end
    assert_equal '', sh.execute('mon ospf ev neighbor | match 2.2.2.2')
    t.join
    lines = out.string.lines.map(&:chomp)
    assert_equal 'Watching neighbor events, Ctrl-C stops', lines[0]
    assert_equal 3, lines.size
    assert_match(/\A\d\d:\d\d:\d\d\.\d{3} neighbor  eth1 neighbor 2\.2\.2\.2 up\z/, lines[1])
    assert_match(/2\.2\.2\.2 full\z/, lines[2])
  ensure
    api&.stop
  end

  def test_monitor_help_lists_the_kinds
    assert_match(/spf\s+Spf events/, @sh.execute('monitor ospf events ?'))
    assert_match(/monitor ospf events/, @sh.execute('help'))
  end
end
