# frozen_string_literal: true

# What routescope reads from ospfd, **copied** from routescope, so this
# repository can hold its own API to it with no routescope here
# (routescope docs/design/api-contract.md, part 3). For each method
# routescope calls, the keys it reads from the answer, as paths: "a.b" is
# key b of key a, "[]" each element of an array, so
# "routes[].next_hops[].gateway". No keys: routescope hands the answer to
# its page whole, or reads only that the call succeeded.
#
# Written by `bundle exec rake vocabulary` in routescope at be270f3
# (jeanmichel-gh/routescope#129, branch claude/api-contract) on
# 2026-11-14, which records what its drivers read while its unit tests
# run. To refresh: run that task in routescope and copy its "ospfd"
# section here. test/unit/daemon/routescope_vocabulary_test.rb holds the
# API to it. Not named *_test.rb, so the test runner does not load it as a
# test.
module RoutescopeVocabulary
  OSPFD = {
    "config.changed" => [],
    "config.commit" => %w[changes errors ok warnings],
    "config.compare" => [],
    "config.discard" => [],
    "config.history" => %w[[].comment],
    "config.replace" => %w[errors],
    "config.rollback" => [],
    "events.subscribe" => [],
    "show.configuration" => [],
    "show.database" => %w[[].advr [].age [].area [].checksum [].detail [].length [].ls_id [].self [].seq [].type [].type_name],
    "show.fib" => %w[configured error install protocol routes routes[].cost routes[].error routes[].have routes[].have[].gateway routes[].metric routes[].path_type routes[].prefix routes[].state routes[].type2_cost routes[].want routes[].want[].gateway table],
    "show.interfaces" => %w[[].address [].adjacent [].area [].bdr_id [].cost [].dead_interval [].dr_id [].hello_interval [].name [].neighbors [].priority [].state_name [].type],
    "show.neighbors" => %w[[].address [].dead_in [].interface [].priority [].role [].router_id [].state [].uptime],
    "show.overview" => %w[areas areas[].lsas external_lsas fib fib.installed router_id spf spf.routes spf.runs],
    "show.routes" => %w[routes routes[].area routes[].cost routes[].next_hops routes[].next_hops[].gateway routes[].next_hops[].interface routes[].path_type routes[].prefix routes[].type2_cost],
    "show.spf" => [],
    "show.timers" => [],
    "show.topology" => %w[area nodes nodes[].abr nodes[].asbr nodes[].id nodes[].kind nodes[].neighbors nodes[].neighbors[].id nodes[].neighbors[].metric nodes[].prefixes nodes[].prefixes[].forwarding nodes[].prefixes[].metric nodes[].prefixes[].prefix nodes[].prefixes[].route_type nodes[].reachable scope],
  }.freeze
end
