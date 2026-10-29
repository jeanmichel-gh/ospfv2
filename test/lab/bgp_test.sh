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
#
# Needs containerlab and sudo. KEEP_LAB=1 leaves the lab up. BGP_TEST_DIR
# is where the lab folder goes (default a new temp dir).
set -uo pipefail
cd "$(dirname "$0")/../.."

WHICH="${1:-ibgp}"
case "$WHICH" in
  ibgp) NAME=bgp-ibgp; FLAG=--bgp ;;
  ospf-bgp) NAME=ospf-bgp; FLAG=--ospf-bgp ;;
  *) echo "usage: $0 ibgp|ospf-bgp"; exit 2 ;;
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
check "r1's kernel goes to r3's loopback through r3" via r1 10.255.1.3 10.1.13.2

if [ "$WHICH" = ospf-bgp ]; then
  step "AS 65000's routes in AS 65001"
  wait_for 30 "r1 has the simulated edge router's loopback from asbr" frr_bgp r1 10.255.0.1/32 10.1.100.1
  wait_for 30 "r2 has it through r1 (next hop self)" frr_bgp r2 10.255.0.1/32 10.1.12.1
  wait_for 30 "r3 (BIRD) has it" bird_bgp r3 10.255.0.1/32
  wait_for 30 "r3's kernel goes there through r1" via r3 10.255.0.1 10.1.13.1
  check "r3 has the simulated area's externals too" r3_externals
  wait_for 30 "asbr has AS 65001's prefixes" frr_bgp asbr 192.168.3.0/24 10.1.100.2
fi

echo
echo "${PASSED} checks passed"
