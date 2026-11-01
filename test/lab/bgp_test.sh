#!/usr/bin/env bash
# The BGP labs, end to end, deployed with containerlab:
#
#   test/lab/bgp_test.sh ibgp       "ospfv2 lab new --bgp": three iBGP speakers in
#                                   AS 65001 (r1, r2 FRR; r3 BIRD), every session
#                                   Established, every router with the others'
#                                   prefixes, in BGP and in its kernel
#   test/lab/bgp_test.sh ospf-bgp   "ospfv2 lab new --ospf-bgp": AS 65000's OSPF
#                                   (the simulator, ospfd, asbr) redistributed into
#                                   BGP, through r1 by eBGP and on to r2, r3 by iBGP
#   test/lab/bgp_test.sh isis-bgp   "ospfv2 lab new --isis-bgp": AS 65000's IS-IS
#                                   (i1, i2 level 1; i3 level 2; asbr both) the
#                                   same way; the MED follows the IS-IS metric, a
#                                   lost link withdraws its prefix from AS 65001
#
# Needs containerlab and sudo. KEEP_LAB=1 leaves the lab up. BGP_TEST_DIR
# is where the lab folder goes (default a new temp dir).
set -uo pipefail
cd "$(dirname "$0")/../.."

WHICH="${1:-ibgp}"
case "$WHICH" in
  ibgp) NAME=bgp-ibgp; FLAG=--bgp ;;
  ospf-bgp) NAME=ospf-bgp; FLAG=--ospf-bgp ;;
  isis-bgp) NAME=isis-bgp; FLAG=--isis-bgp ;;
  *) echo "usage: $0 ibgp|ospf-bgp|isis-bgp"; exit 2 ;;
esac
DIR="${BGP_TEST_DIR:-$(mktemp -d)}/$WHICH"
PASSED=0
STEP=''

step() { STEP="$*"; echo; echo "=== $*"; }
ok() { echo "  ok   $*"; PASSED=$((PASSED + 1)); }
vt() { docker exec "clab-$NAME-$1" vtysh -c "$2"; }
bc() { docker exec "clab-$NAME-$1" birdc "${@:2}"; }
diag() {
  for n in $(docker ps -a --format '{{.Names}}' | grep "^clab-$NAME-" | sed "s/^clab-$NAME-//"); do
    echo "@@$n"
    case "$n" in
      r3) bc r3 show protocols; bc r3 show route count ;;
      sim) docker logs --tail 10 "clab-$NAME-sim" 2>&1 ;;
      ospfd) docker exec "clab-$NAME-ospfd" ospf-cli -c 'show ospf neighbor' ;;
      i[0-9]) vt "$n" 'show isis neighbor'; vt "$n" 'show ip route' ;;
      asbr) vt "$n" 'show bgp summary'; vt "$n" 'show ip ospf neighbor'; vt "$n" 'show isis neighbor' ;;
      *) vt "$n" 'show bgp summary'; vt "$n" 'show ip ospf neighbor' ;;
    esac
    docker exec "clab-$NAME-$n" ip -br addr 2>&1 | grep -v '^lo '
    echo "--- log"; docker logs --tail 15 "clab-$NAME-$n" 2>&1 | cut -c1-200
  done
}
fail() {
  echo "  FAIL $*"
  local out
  out="$(diag 2>&1)"
  echo "$out"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error title=BGP lab $NAME::failed at ${STEP}: $* (after ${PASSED} passed checks)"
    echo "$out" | awk 'BEGIN { RS = "@@" } NF { gsub(/%/, "%25"); gsub(/\n/, "%0A"); split($0, a, "%0A"); printf "::error title=BGP lab: %s::%s\n", a[1], substr($0, 1, 3800) }'
  fi
  exit 1
}
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else fail "$what"; fi; }
wait_for() {
  local secs="$1" what="$2"; shift 2
  local end=$((SECONDS + secs))
  until "$@" >/dev/null 2>&1; do
    ((SECONDS >= end)) && fail "$what (not within ${secs}s)"
    sleep 2
  done
  ok "$what"
}
cleanup() {
  local rc=$?
  if [ -z "${KEEP_LAB:-}" ] && [ -f "$DIR/$NAME.clab.yml" ]; then
    (cd "$DIR" && sudo containerlab destroy -t "$NAME.clab.yml" --cleanup >/dev/null 2>&1) || true
  fi
  [ -n "${GITHUB_ACTIONS:-}" ] && ((rc == 0)) && echo "::notice title=BGP lab $NAME::${PASSED} checks passed"
  exit $rc
}
trap cleanup EXIT

# FRR's session with PEER is Established.
frr_up() { vt "$1" 'show bgp summary json' | ruby -rjson -e 'p = JSON.parse($stdin.read).dig("ipv4Unicast", "peers", ARGV[0]); exit(p && p["state"] == "Established")' "$2"; }
# BIRD's BGP protocol PEER is Established.
bird_up() { bc "$1" show protocols "$2" | grep -q Established; }
# FRR has PREFIX from BGP, its next hop GW when given.
frr_bgp() { local out; out="$(vt "$1" "show ip route $2")"; grep -q 'Known via "bgp"' <<<"$out" && { [ -z "${3:-}" ] || grep -q "\b$3\b" <<<"$out"; }; }
# BIRD has PREFIX from BGP.
bird_bgp() { bc "$1" show route "$2" | grep -q "$2 .*\[r[0-9]"; }
# The kernel routes ADDRESS via GW.
via() { docker exec "clab-$NAME-$1" ip route get "$2" | grep -q "via $3 "; }
r1_has_24s() { frr_bgp r1 192.168.2.0/24 && frr_bgp r1 192.168.3.0/24; }
r2_has_24s() { frr_bgp r2 192.168.1.0/24 && frr_bgp r2 192.168.3.0/24; }
r3_has_24s() { bird_bgp r3 192.168.1.0/24 && bird_bgp r3 192.168.2.0/24; }
asbr_full() { vt asbr 'show ip ospf neighbor' | grep -Eq "^${1//./\\.} .*Full"; }
asbr_ospf_routes() { vt asbr 'show ip route 10.255.0.1' | grep -q 'Known via "ospf"'; }
# asbr's IS-IS adjacency on IFACE, at LEVEL, is Up.
isis_up() { vt asbr 'show isis neighbor' | grep -Eq " $1 +$2 +Up"; }
# NODE's route to ADDRESS came from IS-IS as PREFIX.
isis_route() { local out; out="$(vt "$1" "show ip route $2")"; grep -q 'Known via "isis"' <<<"$out" && grep -q "entry for $3" <<<"$out"; }
# FRR's BGP path to PREFIX has TEXT (a MED, a community).
bgp_has() { vt "$1" "show bgp ipv4 unicast $2" | grep -q "$3"; }
bird_has() { bc "$1" show route all "$2" | grep -q "$3"; }
bird_gone() { ! bc "$1" show route "$2" | grep -q "$2 "; }
# NODE pings ADDRESS from FROM.
pings() { docker exec "clab-$NAME-$1" ping -c 1 -W 2 -I "$3" "$2"; }
r3_externals() { bc r3 show route 50.0.5.0/24 | grep -q '50.0.5.0/24'; }

step "lab folder"
ruby bin/ospfv2 lab new "$DIR" "$FLAG"
check "the topology" test -f "$DIR/$NAME.clab.yml"

step "images"
if [ -z "${SKIP_BUILD:-}" ]; then
  [ "$WHICH" = ospf-bgp ] && docker build -q -t ospfv2 . >/dev/null
  docker build -q -t ospfv2-bird docker/bird >/dev/null
fi
docker image inspect quay.io/frrouting/frr:10.2.1 >/dev/null 2>&1 || docker pull -q quay.io/frrouting/frr:10.2.1 >/dev/null
check "FRR and BIRD images" docker image inspect quay.io/frrouting/frr:10.2.1 ospfv2-bird

step "deploy"
(cd "$DIR" && sudo containerlab deploy -t "$NAME.clab.yml") || fail "containerlab deploy"

if [ "$WHICH" = ospf-bgp ]; then
  step "AS 65000: OSPF"
  wait_for 120 "asbr Full with the simulator" asbr_full 1.1.1.1
  wait_for 90 "asbr Full with ospfd" asbr_full 3.3.3.3
  wait_for 60 "asbr has the simulated area's routes" asbr_ospf_routes
  step "eBGP between the domains"
  wait_for 60 "asbr Established with r1" frr_up asbr 10.1.100.2
  wait_for 30 "r1 Established with asbr" frr_up r1 10.1.100.1
fi

if [ "$WHICH" = isis-bgp ]; then
  step "AS 65000: IS-IS"
  wait_for 90 "asbr Up with i1 at level 1" isis_up eth1 1
  wait_for 60 "asbr Up with i2 at level 1" isis_up eth2 1
  wait_for 60 "asbr Up with i3 at level 2" isis_up eth3 2
  wait_for 30 "asbr has level 1 routes (i1's loopback)" isis_route asbr 10.255.0.1 10.255.0.1/32
  wait_for 30 "asbr has level 2 routes (i3's loopback)" isis_route asbr 10.255.0.3 10.255.0.3/32
  wait_for 30 "i1 (level 1) reaches area 49.0002 by the attached bit's default" isis_route i1 10.255.0.3 0.0.0.0/0
  wait_for 30 "i1's kernel goes there through asbr" via i1 10.255.0.3 10.0.14.2
  wait_for 30 "i1 has i2's /24, external at level 1" isis_route i1 172.16.2.1 172.16.2.0/24
  wait_for 30 "i3 (level 2) has asbr's default" isis_route i3 10.255.1.1 0.0.0.0/0
  wait_for 30 "i3 reaches area 49.0001 by that default too (FRR keeps level 1 out of level 2)" isis_route i3 10.255.0.1 0.0.0.0/0
  wait_for 30 "i3's kernel goes there through asbr" via i3 10.255.0.1 10.0.34.1
  step "eBGP between the domains"
  wait_for 60 "asbr Established with r1" frr_up asbr 10.1.100.2
  wait_for 30 "r1 Established with asbr" frr_up r1 10.1.100.1
fi

step "AS 65001: iBGP, full mesh"
wait_for 90 "r1 Established with r2" frr_up r1 10.1.12.2
wait_for 60 "r1 Established with r3 (BIRD)" frr_up r1 10.1.13.2
wait_for 60 "r2 Established with r1" frr_up r2 10.1.12.1
wait_for 60 "r2 Established with r3 (BIRD)" frr_up r2 10.1.23.2
wait_for 60 "r3 (BIRD) Established with r1" bird_up r3 r1
wait_for 60 "r3 (BIRD) Established with r2" bird_up r3 r2

step "routes"
wait_for 30 "r1 has r2's and r3's /24s" r1_has_24s
wait_for 30 "r2 has r1's and r3's /24s" r2_has_24s
wait_for 30 "r3 (BIRD) has r1's and r2's /24s" r3_has_24s
wait_for 30 "r3's kernel goes to r2's /24 through r2" via r3 192.168.2.1 10.1.23.1
wait_for 30 "r1's kernel goes to r3's loopback through r3" via r1 10.255.1.3 10.1.13.2

if [ "$WHICH" = ospf-bgp ]; then
  step "AS 65000's routes in AS 65001"
  wait_for 30 "r1 has the simulated edge router's loopback from asbr" frr_bgp r1 10.255.0.1/32 10.1.100.1
  wait_for 30 "r2 has it through r1 (next hop self)" frr_bgp r2 10.255.0.1/32 10.1.12.1
  wait_for 30 "r3 (BIRD) has it" bird_bgp r3 10.255.0.1/32
  wait_for 30 "r3's kernel goes there through r1" via r3 10.255.0.1 10.1.13.1
  wait_for 30 "r3 has the simulated area's externals too" r3_externals
  wait_for 30 "asbr has AS 65001's prefixes" frr_bgp asbr 192.168.3.0/24 10.1.100.2
fi

if [ "$WHICH" = isis-bgp ]; then
  step "AS 65000's IS-IS routes in AS 65001"
  wait_for 30 "r1 has i1's loopback from asbr" frr_bgp r1 10.255.0.1/32 10.1.100.1
  check "its MED is its IS-IS metric (20)" bgp_has r1 10.255.0.1/32 'metric 20'
  wait_for 30 "r2 has it through r1 (next hop self)" frr_bgp r2 10.255.0.1/32 10.1.12.1
  wait_for 30 "r3 (BIRD) has it" bird_bgp r3 10.255.0.1/32
  wait_for 30 "r3 has area 49.0002's /24 (i3's)" bird_bgp r3 172.16.3.0/24
  check "with community 65000:2 (route map ISIS-TO-BGP)" bird_has r3 172.16.3.0/24 '(65000,2)'
  check "area 49.0001's /24 has none" bash -c "! docker exec clab-$NAME-r1 vtysh -c 'show bgp ipv4 unicast 172.16.1.0/24' | grep -q Community"
  wait_for 30 "asbr has AS 65001's prefixes" frr_bgp asbr 192.168.3.0/24 10.1.100.2
  wait_for 30 "i1 pings r3 (BIRD), loopback to loopback" pings i1 10.255.1.3 10.255.0.1
  wait_for 30 "i3 pings r2, loopback to loopback" pings i3 10.255.1.2 10.255.0.3

  step "the MED follows the IS-IS metric"
  docker exec "clab-$NAME-asbr" vtysh -c 'configure' -c 'interface eth3' -c 'isis metric 50' >/dev/null
  wait_for 30 "isis metric 50 toward i3: r2 has i3's loopback with MED 60" bgp_has r2 10.255.0.3/32 'metric 60'
  docker exec "clab-$NAME-asbr" vtysh -c 'configure' -c 'interface eth3' -c 'no isis metric 50' >/dev/null
  wait_for 30 "back to MED 20" bgp_has r2 10.255.0.3/32 'metric 20'

  step "a lost link withdraws its prefixes"
  docker exec "clab-$NAME-i3" ip link set eth1 down
  wait_for 45 "i3's link down: r3 (BIRD) loses i3's /24" bird_gone r3 172.16.3.0/24
  docker exec "clab-$NAME-i3" ip link set eth1 up
  wait_for 60 "link up: r3 has it again" bird_bgp r3 172.16.3.0/24
fi

echo
echo "${PASSED} checks passed"
