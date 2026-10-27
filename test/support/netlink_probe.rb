# frozen_string_literal: true

# Runs Fib::Netlink operations inside a network namespace for the netlink
# integration test, and prints one JSON result per operation:
#
#   ip netns exec NS ruby -Ilib test/support/netlink_probe.rb '[["replace", "10.1.0.0/16", [["a", "10.9.0.2"]], 20], ["dump"]]'
#
# A result is {"ok": true}, {"error": "..."} or {"routes": ["10.1.0.0/16 via 10.9.0.2 a metric 20"]}.

require 'json'
require 'ospfv2/fib/netlink'

opts = JSON.parse(ENV.fetch('NETLINK_OPTS', '{}'), symbolize_names: true)
nl = OSPFv2::Fib::Netlink.new(**opts)
addr = ->(s) { OSPFv2::Core::Addr.to_i(s) }
JSON.parse(ARGV.fetch(0)).each do |op, prefix, hops, metric|
  result = begin
    case op
    when 'dump'
      { routes: nl.dump.map(&:to_s).sort }
    else
      p, len = prefix.split('/')
      route = OSPFv2::Fib::Route.new(addr[p], len.to_i, hops.map { |i, g| [i, g && addr[g]] }, metric)
      nl.public_send(op, route)
      { ok: true }
    end
  rescue OSPFv2::Fib::Error => e
    { error: e.message }
  end
  puts JSON.generate(result)
end
