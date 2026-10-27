# frozen_string_literal: true

# Runs one core router on real interfaces and writes its state as JSON
# once a second. Used by the FRR interop tests, which start it inside a
# network namespace:
#
#   ip netns exec ns1 ruby -Ilib test/support/core_runner.rb CONFIG.json STATE.json
#
# CONFIG: {"router_id": "1.1.1.1",
#          "interfaces": [{"name": "veth0", "address": "10.0.12.1/24", "type": "broadcast",
#                          "hello": 1, "dead": 4, "priority": 1, "area": "0.0.0.0", "cost": 10,
#                          "auth": {"type": "md5", "keys": {"1": "secret"}}},
#                         {"name": "lo", "address": "1.1.1.1/32", "passive": true}]}
#
# "areas": {"0.0.0.1": {"stub": {"no_summaries": true}}} sets area options;
# {"nssa": {"default_lsa": {"metric": 5, "type": 2}, "no_summaries": false}}.
#
# "virtual_links": [{"neighbor": "2.2.2.2", "transit_area": "0.0.0.1"}] sets
# up virtual links.
#
# "externals": [{"prefix": "203.0.113.0/24", "metric": 7, "type": 1, "tag": 9}]
# are advertised as AS-external-LSAs.
#
# With "fib": true the routes go into the namespace's kernel table over
# netlink (protocol 89, main table), and SIGTERM withdraws them.
#
# STATE holds neighbors, LSDB keys, packet counters, the routing table,
# and every LSA in hex (lsas: {area: [hex]}, externals: [hex]) so a test
# can rerun SPF on the same database from another router's point of view.
#
# Stops on SIGTERM or SIGINT.

require 'json'
require 'ospfv2/core'
require 'ospfv2/fib'
require 'ospfv2/fib/netlink'

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
router.area_options = (config[:areas] || {}).to_h do |id, o|
  opts = {}
  opts[:stub] = { default_metric: o[:stub][:default_metric], no_summaries: o[:stub][:no_summaries] == true } if o[:stub]
  if o[:nssa]
    dl = o[:nssa][:default_lsa]
    opts[:nssa] = { default_lsa: dl && { metric: dl[:metric] || 1, type: dl[:type] || 2 },
                    no_summaries: o[:nssa][:no_summaries] == true }
  end
  [OSPFv2::Core::Addr.to_i(id.to_s), opts]
end
config.fetch(:interfaces).each do |i|
  ip = i.fetch(:address).split('/').first
  opts = { name: i.fetch(:name), address: i.fetch(:address), area: i[:area] || 0 }
  opts[:cost] = i[:cost] if i[:cost]
  if i[:passive]
    router.add_interface(**opts, passive: true)
  else
    router.add_interface(
      **opts, transport: OSPFv2::Transport::RawSocket.new(ip, interface: i[:name]),
              type: (i[:type] || 'broadcast').to_sym, hello_interval: i[:hello] || 1, dead_interval: i[:dead] || 4,
              priority: i[:priority] || 1, auth: auth_spec(i[:auth])
    )
  end
end
(config[:virtual_links] || []).each do |v|
  router.add_virtual_link(neighbor: v.fetch(:neighbor), transit_area: v.fetch(:transit_area))
end
loop_.call { router.start }
if config[:externals]
  ext = config[:externals].map do |e|
    ip, len = e.fetch(:prefix).split('/')
    { prefix: OSPFv2::Core::Addr.to_i(ip), prefix_len: len.to_i, metric: e[:metric] || 20, type: e[:type] || 2,
      tag: e[:tag] || 0 }
  end
  loop_.call { router.externals = ext }
end
fib = nil
if config[:fib]
  log = ->(level, msg) { warn "#{level} #{msg}" unless level == :debug }
  fib = OSPFv2::Fib::Manager.new(loop: loop_, backend: OSPFv2::Fib::Netlink.new, logger: log)
  loop_.call { fib.attach(router) }
end

stop = false
%w[TERM INT].each { |sig| trap(sig) { stop = true } }

until stop
  state = loop_.call do
    {
      neighbors: router.neighbor_summaries.map { |n| n.slice(:router_id, :address, :state) },
      lsdb: router.database.map { |_, l| [l.type, OSPFv2::Core::Addr.to_s(l.ls_id), OSPFv2::Core::Addr.to_s(l.advr)] }.sort,
      stats: router.interfaces.values.to_h { |i| [i.name, i.stats] },
      routes: router.routes.values.to_h do |r|
        [r.dest_s, { path_type: r.path_type, cost: r.cost, type2_cost: r.type2_cost,
                     next_hops: r.next_hops.map { |h| [h.interface, h.gateway && OSPFv2::Core::Addr.to_s(h.gateway)] } }]
      end,
      lsas: router.areas.values.to_h { |a| [a.id_s, a.lsdb.live.map { |l| l.bytes.unpack1('H*') }] },
      fib: fib && { holding: fib.holding?, failed: fib.failed.size },
      externals: router.as_lsdb.live.map { |l| l.bytes.unpack1('H*') }
    }
  end
  tmp = "#{state_file}.tmp"
  File.write(tmp, JSON.generate(state))
  File.rename(tmp, state_file)
  10.times { sleep 0.1 unless stop }
end
loop_.call do
  router.stop
  fib&.detach
end
