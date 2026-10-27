# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'tmpdir'
require 'open3'

# One FRR ospfd and one core router, each in its own network namespace,
# joined by a veth pair. Needs root, iproute2 and FRR (zebra, ospfd,
# vtysh). The tests that use it run only with OSPFV2_FRR=1.
#
#   lab = FrrLab.new('t1')
#   lab.start(frr_interface: ['ip ospf authentication message-digest',
#                             'ip ospf message-digest-key 1 md5 secret'],
#             core_interface: { auth: { type: 'md5', keys: { '1' => 'secret' } } })
#   lab.wait_for { lab.frr_neighbor_state == 'Full' && lab.core_neighbor_state == 'full' }
#   lab.stop
class FrrLab
  FRR = '/usr/lib/frr'
  ROOT = File.expand_path('../..', __dir__)

  def self.available?
    return [false, 'set OSPFV2_FRR=1 to run the FRR interop tests'] unless ENV['OSPFV2_FRR'] == '1'
    return [false, 'needs root for network namespaces'] unless Process.uid.zero?
    return [false, 'needs FRR (zebra, ospfd, vtysh)'] unless %w[zebra ospfd].all? { |d| File.executable?("#{FRR}/#{d}") } && system('which vtysh > /dev/null')
    return [false, 'needs iproute2'] unless system('which ip > /dev/null')
    [true, nil]
  end

  attr_reader :name, :dir

  def initialize(name)
    @name = name
    @frr_ns = "#{name}-frr"
    @core_ns = "#{name}-core"
    @dir = Dir.mktmpdir("ospfv2-#{name}")
    @run = "/var/run/frr/#{name}"
    @etc = "/etc/frr/#{name}"
  end

  # frr_interface: extra lines under "interface veth0" in FRR
  # core_interface: extra keys for the core interface (auth:, type:, ...)
  # p2p: point-to-point on both sides
  # ospfd: run bin/ospfd with these set lines instead of the bare core
  def start(frr_interface: [], core_interface: {}, p2p: false, ospfd: nil)
    cleanup
    sh "ip netns add #{@frr_ns}"
    sh "ip netns add #{@core_ns}"
    sh "ip link add veth0 netns #{@core_ns} type veth peer name veth0 netns #{@frr_ns}"
    sh "ip -n #{@core_ns} addr add 10.0.12.1/24 dev veth0"
    sh "ip -n #{@frr_ns} addr add 10.0.12.2/24 dev veth0"
    sh "ip -n #{@frr_ns} addr add 2.2.2.2/32 dev lo"
    [@core_ns, @frr_ns].each do |ns|
      sh "ip -n #{ns} link set lo up"
      sh "ip -n #{ns} link set veth0 up"
    end
    sh "ip -n #{@core_ns} addr add 1.1.1.1/32 dev lo"
    start_frr(frr_interface + (p2p ? ['ip ospf network point-to-point'] : []))
    if ospfd
      start_ospfd(ospfd)
    else
      start_core(core_interface.merge(p2p ? { type: 'p2p' } : {}))
    end
    self
  end

  def stop
    Process.kill('TERM', @core_pid) if @core_pid
    Process.wait(@core_pid) if @core_pid
    @core_pid = nil
  rescue Errno::ESRCH, Errno::ECHILD
    @core_pid = nil
  ensure
    cleanup
  end

  # ---- state ----

  def core_state
    JSON.parse(File.read(state_file))
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end

  def core_neighbor_state
    core_state.fetch('neighbors', []).find { |n| n['router_id'] == '2.2.2.2' }&.fetch('state')
  end

  def core_lsdb
    core_state.fetch('lsdb', [])
  end

  def core_stat(key)
    core_state.dig('stats', 'veth0', key.to_s) || 0
  end

  def vtysh(cmd)
    # stdout only: vtysh warns on stderr about a missing vtysh.conf.
    out, = Open3.capture3('vtysh', '-N', @name, '-c', cmd)
    out
  end

  def frr_json(cmd)
    JSON.parse(vtysh("#{cmd} json"))
  rescue JSON::ParserError
    {}
  end

  # "Full", "2-Way", ... as FRR reports it, or nil.
  def frr_neighbor_state
    nbr = frr_json('show ip ospf neighbor').dig('neighbors', '1.1.1.1')
    nbr = nbr.first if nbr.is_a?(Array)
    nbr && (nbr['nbrState'] || nbr['state'])&.split('/')&.first
  end

  # [type, ls_id, advr] for every LSA FRR holds, like core_lsdb.
  def frr_lsdb
    types = { 'routerLinkStates' => 1, 'networkLinkStates' => 2 }
    rows = []
    frr_json('show ip ospf database').fetch('areas', {}).each_value do |area|
      types.each do |section, type|
        area.fetch(section, []).each { |l| rows << [type, l['lsId'], l['advertisedRouter']] }
      end
    end
    rows.sort
  end

  # Runs ospf-cli commands against the ospfd started by start(ospfd:).
  def cli(*commands)
    args = commands.flat_map { |c| ['-c', c] }
    out, = Open3.capture2e(RbConfig.ruby, "#{ROOT}/bin/ospf-cli", '-s', socket_path, *args)
    out
  end

  def socket_path = File.join(@dir, 'ospfd.sock')

  # Our routes in the core namespace's kernel table.
  def core_kernel_routes
    `ip -n #{@core_ns} route show proto 89`.lines.map(&:strip).reject(&:empty?)
  end

  def core_log
    File.read(File.join(@dir, 'core.log'))
  rescue Errno::ENOENT
    ''
  end

  def wait_for(timeout = 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.5
    end
    true
  end

  private

  def state_file = File.join(@dir, 'state.json')

  def start_frr(iface_lines)
    FileUtils.mkdir_p([@run, @etc])
    conf = File.join(@etc, 'frr.conf')
    File.write(conf, <<~CONF)
      hostname #{@name}
      interface veth0
       ip ospf hello-interval 1
       ip ospf dead-interval 4
      #{iface_lines.map { |l| " #{l}" }.join("\n")}
      router ospf
       ospf router-id 2.2.2.2
       network 10.0.12.0/24 area 0
       network 2.2.2.2/32 area 0
    CONF
    sh "chown -R frr:frr #{@run} #{@etc}"
    %w[zebra ospfd].each do |d|
      sh "ip netns exec #{@frr_ns} #{FRR}/#{d} -N #{@name} -d -f #{conf} -i #{@run}/#{d}.pid > /dev/null 2>&1"
    end
  end

  def start_core(iface)
    cfg = { router_id: '1.1.1.1',
            interfaces: [{ name: 'veth0', address: '10.0.12.1/24', hello: 1, dead: 4, **iface }] }
    File.write(File.join(@dir, 'core.json'), JSON.generate(cfg))
    @core_pid = Process.spawn('ip', 'netns', 'exec', @core_ns, RbConfig.ruby, "-I#{ROOT}/lib",
                              "#{ROOT}/test/support/core_runner.rb", File.join(@dir, 'core.json'), state_file,
                              %i[out err] => File.join(@dir, 'core.log'))
  end

  def start_ospfd(lines)
    conf = File.join(@dir, 'ospfd.conf')
    File.write(conf, lines.join("\n"))
    @core_pid = Process.spawn('ip', 'netns', 'exec', @core_ns, RbConfig.ruby, "#{ROOT}/bin/ospfd",
                              '-f', conf, '-s', socket_path, '-l', File.join(@dir, 'core.log'),
                              %i[out err] => File.join(@dir, 'ospfd.out'))
  end

  def cleanup
    %w[ospfd zebra].each do |d|
      pid_file = "#{@run}/#{d}.pid"
      next unless File.exist?(pid_file)
      begin
        Process.kill('TERM', File.read(pid_file).to_i)
      rescue Errno::ESRCH
        nil
      end
      File.delete(pid_file)
    end
    sleep 0.3
    [@frr_ns, @core_ns].each { |ns| system("ip netns del #{ns} 2>/dev/null") }
  end

  def sh(cmd)
    system(cmd) or raise "failed: #{cmd}"
  end
end
