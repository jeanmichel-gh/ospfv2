# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'tmpdir'
require 'open3'
require 'ospfv2/core'
require_relative 'frr_lab'

# Several routers, FRR or core, one network namespace each, joined by
# veth pairs. Needs what FrrLab needs. Interface names are the peer's
# name with a suffix per parallel link: r1's link to r2 is "r2a".
#
#   t = FrrTopology.new('spf')
#   t.core('r1', '1.1.1.1')
#   t.frr('r2', '2.2.2.2')
#   t.link('r1', 'r2', '10.0.12.0/24')            # broadcast, area 0
#   t.link('r2', 'r3', '10.0.23.0/30', p2p: true, area: 1)
#   t.start
#   t.frr_routes('r2'); t.core_state('r1')
#   t.stop
class FrrTopology
  FRR = FrrLab::FRR
  ROOT = FrrLab::ROOT

  Router = Struct.new(:name, :kind, :router_id, :loopback_area, :extra, :frr_extra, :dummies, :links, :fib,
                      keyword_init: true)
  Link = Struct.new(:ifname, :peer, :address, :prefix_len, :p2p, :area, :cost, keyword_init: true)

  attr_reader :routers, :dir

  def initialize(name)
    @name = name
    @routers = {}
    @dir = Dir.mktmpdir("ospfv2-#{name}")
    @pids = {}
  end

  # extra: lines under "router ospf"; frr_extra: top-level lines (route-maps)
  # dummies: { 'ext1' => '192.0.2.1/24' } networks outside OSPF, to redistribute
  def frr(name, router_id, loopback_area: 0, extra: [], frr_extra: [], dummies: {})
    @routers[name] = Router.new(name: name, kind: :frr, router_id: router_id, loopback_area: loopback_area,
                                extra: extra, frr_extra: frr_extra, dummies: dummies, links: [])
  end

  # fib: install routes in the namespace's kernel table
  def core(name, router_id, loopback_area: 0, fib: false)
    @routers[name] = Router.new(name: name, kind: :core, router_id: router_id, loopback_area: loopback_area,
                                extra: [], frr_extra: [], dummies: {}, links: [], fib: fib)
  end

  # Joins a and b on +subnet+; a gets the first host address, b the second.
  def link(a, b, subnet, p2p: false, area: 0, cost: 10)
    net, len = subnet.split('/')
    base = OSPFv2::Core::Addr.to_i(net)
    [[a, b, 1], [b, a, 2]].each do |me, peer, host|
      r = @routers.fetch(me)
      n = r.links.count { |l| l.peer == peer }
      r.links << Link.new(ifname: "#{peer}#{('a'.ord + n).chr}", peer: peer,
                          address: OSPFv2::Core::Addr.to_s(base + host), prefix_len: len.to_i,
                          p2p: p2p, area: area, cost: cost)
    end
  end

  def ns(name) = "#{@name}-#{name}"
  def pathspace(name) = "#{@name}-#{name}"

  def start
    cleanup
    @routers.each_value do |r|
      sh "ip netns add #{ns(r.name)}"
      sh "ip -n #{ns(r.name)} link set lo up"
      sh "ip netns exec #{ns(r.name)} sysctl -qw net.ipv4.ip_forward=1"
      sh "ip -n #{ns(r.name)} addr add #{r.router_id}/32 dev lo"
      r.dummies.each do |dev, addr|
        # A veth pair inside the namespace: a connected network that
        # leads nowhere (not every kernel has the dummy driver).
        sh "ip -n #{ns(r.name)} link add #{dev} type veth peer name #{dev}x"
        sh "ip -n #{ns(r.name)} addr add #{addr} dev #{dev}"
        sh "ip -n #{ns(r.name)} link set #{dev}x up"
        sh "ip -n #{ns(r.name)} link set #{dev} up"
      end
    end
    done = {}
    @routers.each_value do |r|
      r.links.each do |l|
        peer = @routers.fetch(l.peer)
        back = peer.links.find { |x| x.peer == r.name && x.ifname[-1] == l.ifname[-1] }
        key = [[r.name, l.ifname], [peer.name, back.ifname]].sort
        next if done[key]
        done[key] = true
        sh "ip link add #{l.ifname} netns #{ns(r.name)} type veth peer name #{back.ifname} netns #{ns(peer.name)}"
        [[r, l], [peer, back]].each do |rr, ll|
          sh "ip -n #{ns(rr.name)} addr add #{ll.address}/#{ll.prefix_len} dev #{ll.ifname}"
          sh "ip -n #{ns(rr.name)} link set #{ll.ifname} up"
        end
      end
    end
    @routers.each_value { |r| r.kind == :frr ? start_frr(r) : start_core(r) }
    self
  end

  def stop
    @pids.keys.each { |name| stop_core(name) }
  ensure
    cleanup
  end

  # Stops a core router: TERM is a clean stop, KILL a crash.
  def stop_core(name, signal: 'TERM')
    pid = @pids.delete(name) or return
    Process.kill(signal, pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def restart_core(name)
    File.delete(state_file(name)) if File.exist?(state_file(name))
    start_core(@routers.fetch(name))
  end

  # Runs a command in a router's namespace; returns [output, success].
  def run_in(name, *cmd)
    out, st = Open3.capture2e('ip', 'netns', 'exec', ns(name), *cmd)
    [out, st.success?]
  end

  def kernel_routes(name, proto: 89)
    run_in(name, 'ip', 'route', 'show', 'proto', proto.to_s).first.lines.map(&:strip).reject(&:empty?).sort
  end

  # ---- state ----

  def vtysh(name, cmd)
    out, = Open3.capture3('vtysh', '-N', pathspace(name), '-c', cmd)
    out
  end

  def frr_json(name, cmd)
    JSON.parse(vtysh(name, "#{cmd} json"))
  rescue JSON::ParserError
    {}
  end

  def core_state(name)
    JSON.parse(File.read(state_file(name)))
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end

  def core_log(name)
    File.read(File.join(@dir, "#{name}.log"))
  rescue Errno::ENOENT
    ''
  end

  def wait_for(timeout = 60)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.5
    end
    true
  end

  private

  def state_file(name) = File.join(@dir, "#{name}.state.json")

  def start_frr(r)
    run = "/var/run/frr/#{pathspace(r.name)}"
    etc = "/etc/frr/#{pathspace(r.name)}"
    FileUtils.mkdir_p([run, etc])
    conf = File.join(etc, 'frr.conf')
    lines = ["hostname #{r.name}"]
    r.links.each do |l|
      lines << "interface #{l.ifname}"
      lines << ' ip ospf hello-interval 1' << ' ip ospf dead-interval 4' << " ip ospf cost #{l.cost}"
      lines << ' ip ospf network point-to-point' if l.p2p
    end
    lines.concat(r.frr_extra)
    lines << 'router ospf' << " ospf router-id #{r.router_id}"
    r.links.each do |l|
      net = OSPFv2::Core::Addr.to_i(l.address) & OSPFv2::Core::Addr.mask(l.prefix_len)
      lines << " network #{OSPFv2::Core::Addr.to_s(net)}/#{l.prefix_len} area #{l.area}"
    end
    lines << " network #{r.router_id}/32 area #{r.loopback_area}"
    lines.concat(r.extra.map { |x| " #{x}" })
    File.write(conf, "#{lines.join("\n")}\n")
    sh "chown -R frr:frr #{run} #{etc}"
    %w[zebra ospfd].each do |d|
      sh "ip netns exec #{ns(r.name)} #{FRR}/#{d} -N #{pathspace(r.name)} -d -f #{conf} -i #{run}/#{d}.pid > /dev/null 2>&1"
    end
  end

  def start_core(r)
    ifaces = r.links.map do |l|
      { name: l.ifname, address: "#{l.address}/#{l.prefix_len}", type: l.p2p ? 'p2p' : 'broadcast',
        area: OSPFv2::Core::Addr.to_s(l.area), cost: l.cost, hello: 1, dead: 4 }
    end
    ifaces << { name: 'lo', address: "#{r.router_id}/32", passive: true, area: OSPFv2::Core::Addr.to_s(r.loopback_area) }
    cfg = File.join(@dir, "#{r.name}.json")
    File.write(cfg, JSON.generate(router_id: r.router_id, interfaces: ifaces, fib: r.fib))
    @pids[r.name] = Process.spawn('ip', 'netns', 'exec', ns(r.name), RbConfig.ruby, "-I#{ROOT}/lib",
                                  "#{ROOT}/test/support/core_runner.rb", cfg, state_file(r.name),
                                  %i[out err] => [File.join(@dir, "#{r.name}.log"), 'a'])
  end

  def cleanup
    @routers.each_value do |r|
      next unless r.kind == :frr
      %w[ospfd zebra].each do |d|
        pid_file = "/var/run/frr/#{pathspace(r.name)}/#{d}.pid"
        next unless File.exist?(pid_file)
        begin
          Process.kill('TERM', File.read(pid_file).to_i)
        rescue Errno::ESRCH
          nil
        end
        File.delete(pid_file)
      end
    end
    sleep 0.3
    @routers.each_key { |n| system("ip netns del #{ns(n)} 2>/dev/null") }
  end

  def sh(cmd)
    system(cmd) or raise "failed: #{cmd}"
  end
end
