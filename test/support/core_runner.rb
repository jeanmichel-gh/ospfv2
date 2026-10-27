# frozen_string_literal: true

# Runs one core router on real interfaces and writes its state as JSON
# once a second. Used by the FRR interop tests, which start it inside a
# network namespace:
#
#   ip netns exec ns1 ruby -Ilib test/support/core_runner.rb CONFIG.json STATE.json
#
# CONFIG: {"router_id": "1.1.1.1",
#          "interfaces": [{"name": "veth0", "address": "10.0.12.1/24", "type": "broadcast",
#                          "hello": 1, "dead": 4, "priority": 1,
#                          "auth": {"type": "md5", "keys": {"1": "secret"}}}]}
#
# Stops on SIGTERM or SIGINT.

require 'json'
require 'ospfv2/core'

config = JSON.parse(File.read(ARGV.fetch(0)), symbolize_names: true)
state_file = ARGV.fetch(1)

def auth_spec(spec)
  return nil unless spec
  spec = spec.dup
  spec[:type] = spec[:type].to_sym
  spec[:keys] = spec[:keys].to_h { |id, secret| [id.to_s.to_i, secret] } if spec[:keys].is_a?(Hash)
  spec
end

loop_ = OSPFv2::EventLoop.new.start
router = OSPFv2::Core::Instance.new(
  router_id: config.fetch(:router_id), loop: loop_,
  logger: ->(level, msg) { warn "#{level} #{msg}" unless level == :debug }
)
config.fetch(:interfaces).each do |i|
  ip = i.fetch(:address).split('/').first
  router.add_interface(
    name: i.fetch(:name), address: i.fetch(:address),
    transport: OSPFv2::Transport::RawSocket.new(ip, interface: i[:name]),
    type: (i[:type] || 'broadcast').to_sym, hello_interval: i[:hello] || 1, dead_interval: i[:dead] || 4,
    priority: i[:priority] || 1, auth: auth_spec(i[:auth])
  )
end
loop_.call { router.start }

%w[TERM INT].each { |sig| trap(sig) { exit } }

loop do
  state = loop_.call do
    {
      neighbors: router.neighbor_summaries.map { |n| n.slice(:router_id, :address, :state) },
      lsdb: router.database.map { |_, l| [l.type, OSPFv2::Core::Addr.to_s(l.ls_id), OSPFv2::Core::Addr.to_s(l.advr)] }.sort,
      stats: router.interfaces.values.to_h { |i| [i.name, i.stats] }
    }
  end
  tmp = "#{state_file}.tmp"
  File.write(tmp, JSON.generate(state))
  File.rename(tmp, state_file)
  sleep 1
end
