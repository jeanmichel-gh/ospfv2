#!/usr/bin/env bash
# The containerlab lab, end to end: "ospfv2 lab new --containerlab", the
# images built, the ring deployed with containerlab, every adjacency Full,
# the simulated area's routes on ospfd and BIRD, and ospfd going the
# other way round when the link from FRR fails. Needs containerlab and
# sudo. KEEP_LAB=1 leaves the lab up (routescope's CI uses it).
#
#   test/lab/clab_test.sh            from the ospfv2 folder
set -uo pipefail
cd "$(dirname "$0")/../.."

DIR="${CLAB_TEST_DIR:-$(mktemp -d)}/ring"
NAME=ospf-ring
PASSED=0
STEP=''

step() { STEP="$*"; echo; echo "=== $*"; }
ok() { echo "  ok   $*"; PASSED=$((PASSED + 1)); }
fail() {
  echo "  FAIL $*"
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=Containerlab lab::failed at ${STEP}: $* (after ${PASSED} passed checks)"
  echo "--- frr"; docker exec clab-$NAME-frr vtysh -c 'show ip ospf neighbor' 2>&1 || true
  echo "--- ospfd"; docker exec clab-$NAME-ospfd ospf-cli -c 'show ospf neighbor' 2>&1 || true
  echo "--- bird"; docker exec clab-$NAME-bird birdc show ospf neighbors 2>&1 || true
  for n in sim frr ospfd bird; do echo "--- logs $n"; docker logs --tail 30 clab-$NAME-$n 2>&1 || true; done
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
  [ -n "${GITHUB_ACTIONS:-}" ] && ((rc == 0)) && echo "::notice title=Containerlab lab::${PASSED} checks passed"
  exit $rc
}
trap cleanup EXIT

vtysh() { docker exec clab-$NAME-frr vtysh -c "$*"; }
cli() { docker exec clab-$NAME-ospfd ospf-cli -c "$*"; }
birdc() { docker exec clab-$NAME-bird birdc "$@"; }
frr_full() { vtysh 'show ip ospf neighbor' | grep -Eq "^$1 .*Full"; }
ospfd_full() { cli 'show ospf neighbor' | grep -Eq "Full +$1 "; }
ospfd_routes() { local n; n="$(cli 'show route protocol ospf | count' | grep -o '[0-9]\+' | head -1)"; [ "${n:-0}" -ge 250 ]; }
bird_routes() { local n; n="$(birdc show route protocol ospf1 count | grep -o '^[0-9]\+' | head -1)"; [ "${n:-0}" -ge 250 ]; }
ospfd_via() { docker exec clab-$NAME-ospfd ip route get "$1" | grep -q "via $2 "; }

step "lab folder"
ruby bin/ospfv2 lab new "$DIR" --containerlab
check "the topology and one folder per node" test -f "$DIR/$NAME.clab.yml" -a -d "$DIR/bird" -a -d "$DIR/ospfd"

step "images"
if [ -z "${SKIP_BUILD:-}" ]; then
  docker build -q -t ospfv2 . >/dev/null && docker build -q -t ospfv2-bird docker/bird >/dev/null
fi
check "ospfv2 image" docker image inspect ospfv2
check "ospfv2-bird image" docker image inspect ospfv2-bird

step "deploy"
(cd "$DIR" && sudo containerlab deploy -t "$NAME.clab.yml") || fail "containerlab deploy"
wait_for 120 "frr Full with the simulator" frr_full 1.1.1.1
wait_for 90 "frr Full with ospfd" frr_full 3.3.3.3
wait_for 90 "frr Full with bird" frr_full 4.4.4.4
wait_for 60 "ospfd Full with bird" ospfd_full 4.4.4.4

step "routes"
wait_for 90 "ospfd installs the simulated area's routes (250 or more)" ospfd_routes
wait_for 60 "bird has them too" bird_routes
check "ospfd reaches FRR's loopback straight over eth1" ospfd_via 2.2.2.2 10.0.23.1

step "a link fails: ospfd goes round by BIRD"
docker exec clab-$NAME-frr ip link set eth2 down
wait_for 30 "ospfd reaches FRR through BIRD" ospfd_via 2.2.2.2 10.0.34.2
docker exec clab-$NAME-frr ip link set eth2 up
wait_for 60 "the link back: straight again" ospfd_via 2.2.2.2 10.0.23.1

echo
echo "${PASSED} checks passed"
