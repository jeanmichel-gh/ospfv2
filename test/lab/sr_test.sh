#!/usr/bin/env bash
# The SR-MPLS labs and their gate (docs/design/sr-ospf.md, "Gates", step
# 4): routescope/labs/ospf-sr-frr, ospfd between two FRR routers, then
# routescope/labs/ospf-sr, four ospfd routers.
#
#   ospf-sr-frr: every router Full; o1's label table is its kernel's; a
#   ping from f1's loopback to f2's crosses on labels, tcpdump showing
#   17004 into o1, 18004 from o1 to o2, plain IP from o2 to f2; the way
#   back too; FRR lists o1 and o2 with their SRGBs; o1's link to o2 down
#   leaves no label through it, and up brings them back.
#   ospf-sr: the same labels along four ospfd routers, and the ping.
#
# Needs containerlab, sudo, the mpls_router and mpls_iptunnel modules, and
# bfd4r beside this repository (../bfd4r). LABS="ospf-sr-frr" runs one.
# KEEP_LAB=1 leaves the labs up. IMAGE=ospfv2:mine builds and runs that
# tag instead of ospfv2:latest; SKIP_BUILD=1 uses it as it is.
#
#   test/lab/sr_test.sh            from the ospfv2 folder
set -uo pipefail
cd "$(dirname "$0")/../.."

BASE="${SR_TEST_DIR:-$(mktemp -d)}"
IMAGE="${IMAGE:-ospfv2:latest}"
LABS="${LABS:-ospf-sr-frr ospf-sr}"
PASSED=0
STEP=''
NAME=''
DEPLOYED=()

step() { STEP="$*"; echo; echo "=== $*"; }
ok() { echo "  ok   $*"; PASSED=$((PASSED + 1)); }
fail() {
  echo "  FAIL $*"
  local diag
  diag="$( {
    for n in $(nodes); do
      echo "--- $n"
      if [[ $n == f* ]]; then
        docker exec "clab-$NAME-$n" vtysh -c 'show ip ospf neighbor' -c 'show mpls table'
      else
        api "$n" show.neighbors; api "$n" show.labels
        docker exec "clab-$NAME-$n" ip -M route
        docker logs --tail 20 "clab-$NAME-$n"
      fi
    done
  } 2>&1 )"
  echo "$diag"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error title=SR lab::$NAME failed at ${STEP}: $* (after ${PASSED} passed checks)"
    echo "::error title=SR lab state::$(echo "$diag" | tail -n 120 | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')"
  fi
  exit 1
}
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else fail "$what"; fi; }
wait_for() {
  local secs="$1" what="$2"; shift 2
  local end=$((SECONDS + secs))
  until "$@" >/dev/null 2>&1; do
    ((SECONDS >= end)) && fail "$what (not within ${secs}s)"
    sleep 1
  done
  ok "$what"
}
cleanup() {
  local rc=$?
  if [ -z "${KEEP_LAB:-}" ]; then
    for lab in "${DEPLOYED[@]}"; do
      (cd "$BASE/$lab" && sudo containerlab destroy -t "$lab.clab.yml" --cleanup >/dev/null 2>&1) || true
    done
  fi
  [ -n "${GITHUB_ACTIONS:-}" ] && ((rc == 0)) && echo "::notice title=SR lab::${PASSED} checks passed"
  exit $rc
}
trap cleanup EXIT

nodes() { case "$NAME" in ospf-sr-frr) echo f1 o1 o2 f2 ;; ospf-sr) echo o1 o2 o3 o4 ;; esac; }
# One ospfd API call, its answer as JSON.
api() {
  docker exec "clab-$NAME-$1" ruby -rsocket -rjson -e '
    s = UNIXSocket.new("/run/ospfv2/ospfd.sock")
    s.puts JSON.generate(id: 1, method: ARGV[0], params: {})
    r = JSON.parse(s.gets)
    puts JSON.generate(r["result"] || r)' "$2"
}
# ospfd +node+'s neighbors all Full, and +n+ of them.
ospfd_full() {
  api "$1" show.neighbors | ruby -rjson -e 'n = JSON.parse($stdin.read); exit(n.size == ARGV[0].to_i && n.all? { _1["state"] == "full" } ? 0 : 1)' "$2"
}
frr_full() { docker exec "clab-$NAME-$1" vtysh -c 'show ip ospf neighbor' | grep -q 'Full'; }
# ospfd's label +label+: "op out-labels via", e.g. "swap 18004 10.0.23.2".
label() {
  api "$1" show.labels | ruby -rjson -e '
    e = JSON.parse($stdin.read).find { _1["label"] == ARGV[0].to_i }
    puts e ? [e["op"], e["next_hops"].map { _1["label"] }.join(","), e["next_hops"].map { _1["address"] }.join(",")].join(" ") : "none"' "$2"
}
has_label() { [ "$(label "$1" "$2")" = "$3" ]; }
# ospfd's label table against its kernel's: each in-label and its
# out-label (3 for a pop) the same in both, nothing more.
kernel_matches() {
  local want have
  want=$(api "$1" show.labels | ruby -rjson -e 'puts JSON.parse($stdin.read).flat_map { |e| e["next_hops"].map { |h| [e["label"], h["label"] == 3 ? 3 : h["label"], h["address"]].join(" ") } }.sort')
  have=$(docker exec "clab-$NAME-$1" ip -j -M route | ruby -rjson -e 'puts JSON.parse($stdin.read).flat_map { |k| (k["nexthops"] || [k]).map { |h| [k["dst"].to_i, h["to"] ? h["to"].to_s.split("/").first.to_i : 3, h.dig("via", "host")].join(" ") } }.sort')
  [ -n "$want" ] && [ "$want" = "$have" ]
}
# tcpdump in +node+'s container on +dev+ for +filter+, while +from+ pings
# +to+ from its loopback +src+: was a packet seen?
seen() {
  local node="$1" dev="$2" filter="$3" from="$4" src="$5" to="$6"
  docker exec -d "clab-$NAME-$node" sh -c "rm -f /tmp/seen; timeout 8 tcpdump -nn -c 1 -i $dev $filter > /tmp/seen 2>/dev/null"
  sleep 1.5
  netns_ping "$from" -c 3 -i 0.3 -I "$src" "$to" >/dev/null 2>&1
  sleep 1
  docker exec "clab-$NAME-$node" sh -c 'test -s /tmp/seen' && docker exec "clab-$NAME-$node" cat /tmp/seen
}
# The ospfv2 image has no ping: the host's, in the node's network
# namespace, as bfd_test.sh runs tc.
netns_ping() {
  local node="$1"; shift
  sudo nsenter -t "$(docker inspect -f '{{.State.Pid}}' "clab-$NAME-$node")" -n ping "$@"
}
ping_ok() { netns_ping "$1" -c 2 -W 1 -I "$2" "$3"; }
link() { docker exec "clab-$NAME-$1" ip link set "$2" "$3"; }

step "image"
if [ -z "${SKIP_BUILD:-}" ]; then
  test/lab/bases.sh Dockerfile || fail "base images"
  docker build -q -t "$IMAGE" --build-context bfd4r="${BFD4R:-../bfd4r}" . >/dev/null || fail "docker build"
fi
check "ospfv2 image" docker image inspect "$IMAGE"
check "MPLS in the host's kernel" test -e /proc/sys/net/mpls/platform_labels

deploy() {
  NAME="$1"
  step "$NAME: deploy"
  mkdir -p "$BASE"
  cp -r "routescope/labs/$NAME" "$BASE/"
  sed -i "s|image: ospfv2:latest|image: $IMAGE|" "$BASE/$NAME/$NAME.clab.yml"
  (cd "$BASE/$NAME" && sudo containerlab deploy -t "$NAME.clab.yml") || fail "containerlab deploy"
  DEPLOYED+=("$NAME")
}

for lab in $LABS; do
  case "$lab" in
  ospf-sr-frr)
    deploy ospf-sr-frr
    wait_for 120 "o1 Full with f1 and o2" ospfd_full o1 2
    wait_for 60 "o2 Full with o1 and f2" ospfd_full o2 2
    wait_for 60 "f1 Full" frr_full f1
    wait_for 60 "f2 Full" frr_full f2

    step "ospf-sr-frr: labels"
    wait_for 60 "o1 swaps 17004 to 18004 toward o2" has_label o1 17004 "swap 18004 10.0.23.2"
    wait_for 30 "o1 pops 17001 before f1 (PHP)" has_label o1 17001 "php 3 10.0.12.1"
    wait_for 30 "o2 pops 18004 before f2 (PHP)" has_label o2 18004 "php 3 10.0.34.2"
    wait_for 30 "o2 swaps 18001 to 17001 toward o1" has_label o2 18001 "swap 17001 10.0.23.1"
    wait_for 30 "o1's label table is its kernel's" kernel_matches o1
    wait_for 30 "o2's label table is its kernel's" kernel_matches o2
    check "FRR f1 lists o1 with SRGB 17000" sh -c "docker exec clab-$NAME-f1 vtysh -c 'show ip ospf database segment-routing json' | ruby -rjson -e 'n = JSON.parse(\$stdin.read)[\"srNodes\"].find { _1[\"routerID\"] == \"10.255.0.2\" }; exit(n && n[\"srgbLabel\"] == 17000 ? 0 : 1)'"
    check "FRR f1 lists o2 with SRGB 18000" sh -c "docker exec clab-$NAME-f1 vtysh -c 'show ip ospf database segment-routing json' | ruby -rjson -e 'n = JSON.parse(\$stdin.read)[\"srNodes\"].find { _1[\"routerID\"] == \"10.255.0.3\" }; exit(n && n[\"srgbLabel\"] == 18000 ? 0 : 1)'"

    step "ospf-sr-frr: a ping on labels"
    wait_for 30 "f1's loopback reaches f2's" ping_ok f1 10.255.0.1 10.255.0.4
    check "into o1 on 17004" seen o1 eth1 "mpls 17004" f1 10.255.0.1 10.255.0.4
    check "from o1 to o2 on 18004" seen o1 eth2 "mpls 18004" f1 10.255.0.1 10.255.0.4
    check "from o2 to f2 as plain IP" seen o2 eth2 "icmp and src 10.255.0.1" f1 10.255.0.1 10.255.0.4
    check "back from o2 to o1 on 17001" seen o2 eth1 "mpls 17001" f1 10.255.0.1 10.255.0.4

    step "ospf-sr-frr: o1's link to o2 down and up"
    link o1 eth2 down
    wait_for 30 "o1 holds no label through o2" sh -c "! docker exec clab-$NAME-o1 ip -M route | grep -q 10.0.23.2"
    wait_for 30 "o1's label table is its kernel's" kernel_matches o1
    link o1 eth2 up
    wait_for 60 "o1 Full with o2 again" ospfd_full o1 2
    wait_for 60 "o1 swaps 17004 to 18004 again" has_label o1 17004 "swap 18004 10.0.23.2"
    wait_for 30 "o1's label table is its kernel's" kernel_matches o1
    wait_for 30 "the ping crosses again" ping_ok f1 10.255.0.1 10.255.0.4
    ;;
  ospf-sr)
    deploy ospf-sr
    wait_for 120 "o2 Full with o1 and o3" ospfd_full o2 2
    wait_for 60 "o3 Full with o2 and o4" ospfd_full o3 2

    step "ospf-sr: labels"
    wait_for 60 "o1 swaps 16004 to 17004 toward o2" has_label o1 16004 "swap 17004 10.0.12.2"
    wait_for 30 "o2 swaps 17004 to 18004 toward o3" has_label o2 17004 "swap 18004 10.0.23.2"
    wait_for 30 "o3 pops 18004 before o4 (PHP)" has_label o3 18004 "php 3 10.0.34.2"
    for n in o1 o2 o3 o4; do wait_for 30 "$n's label table is its kernel's" kernel_matches $n; done

    step "ospf-sr: a ping on labels"
    wait_for 30 "o1's loopback reaches o4's" ping_ok o1 10.255.0.1 10.255.0.4
    check "from o1 to o2 on 17004" seen o1 eth1 "mpls 17004" o1 10.255.0.1 10.255.0.4
    check "from o2 to o3 on 18004" seen o2 eth2 "mpls 18004" o1 10.255.0.1 10.255.0.4
    check "from o3 to o4 as plain IP" seen o3 eth2 "icmp and src 10.255.0.1" o1 10.255.0.1 10.255.0.4
    ;;
  *) fail "no lab $lab" ;;
  esac
done
echo
echo "${PASSED} checks passed"
