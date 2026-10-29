#!/usr/bin/env bash
# The SR Linux lab, end to end: "ospfv2 lab new --srlinux", deployed with
# containerlab: the simulator Full with SR Linux on the LAN, ospfd Full
# with it on a point-to-point link, and the simulated area's routes on
# ospfd through SR Linux. Needs containerlab, sudo and the SR Linux image.
# KEEP_LAB=1 leaves the lab up. SRL_PROBE_DIR=DIR writes what SR Linux
# answers to a few commands there, one file each (routescope reads them).
#
#   test/lab/srl_test.sh            from the ospfv2 folder
set -uo pipefail
cd "$(dirname "$0")/../.."

DIR="${SRL_TEST_DIR:-$(mktemp -d)}/srl"
NAME=ospf-srl
SRL=clab-$NAME-srl
PASSED=0
STEP=''

step() { STEP="$*"; echo; echo "=== $*"; }
ok() { echo "  ok   $*"; PASSED=$((PASSED + 1)); }
sr() { docker exec "$SRL" sr_cli "$*"; }
cli() { docker exec clab-$NAME-ospfd ospf-cli -c "$*"; }
fail() {
  echo "  FAIL $*"
  local diag
  diag="$( {
    echo "--- srl neighbors"; sr show network-instance default protocols ospf neighbor
    echo "--- srl interfaces"; sr show network-instance default protocols ospf interface
    echo "--- srl ports"; sr show interface ethernet-1/1; sr show interface ethernet-1/2
    echo "--- srl LAN interface counters"; sr info from state network-instance default protocols ospf instance main area 0.0.0.0 interface ethernet-1/1.0 statistics
    echo "--- packets on the LAN, 8 s"; docker exec clab-$NAME-sim timeout 8 ospfv2 capture -i eth1 | cut -c1-400 | head -40
    echo "--- sim log"; docker exec clab-$NAME-sim tail -n 40 /tmp/ospfv2.log
    echo "--- srl config"; sr info network-instance default protocols ospf
    echo "--- ospfd"; cli 'show ospf neighbor'; cli 'show ospf interface'
    for n in sim srl ospfd; do echo "--- logs $n"; docker logs --tail 15 clab-$NAME-$n; done
  } 2>&1 )"
  echo "$diag"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error title=SR Linux lab::failed at ${STEP}: $* (after ${PASSED} passed checks)"
    echo "::error title=SR Linux lab state::$(echo "$diag" | tail -n 200 | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')"
  fi
  exit 1
}
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else fail "$what"; fi; }
wait_for() {
  local secs="$1" what="$2"; shift 2
  local end=$((SECONDS + secs))
  until "$@" >/dev/null 2>&1; do
    ((SECONDS >= end)) && fail "$what (not within ${secs}s)"
    sleep 3
  done
  ok "$what"
}
cleanup() {
  local rc=$?
  if [ -z "${KEEP_LAB:-}" ] && [ -f "$DIR/$NAME.clab.yml" ]; then
    (cd "$DIR" && sudo containerlab destroy -t "$NAME.clab.yml" --cleanup >/dev/null 2>&1) || true
  fi
  [ -n "${GITHUB_ACTIONS:-}" ] && ((rc == 0)) && echo "::notice title=SR Linux lab::${PASSED} checks passed"
  exit $rc
}
trap cleanup EXIT

sim_full() {
  docker exec clab-$NAME-sim ruby -rjson -rnet/http -e \
    'exit(JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:8080/api/state"))).dig("neighbor", "state") == "full")'
}
srl_answers() { sr show version | grep -qi 'software version'; }
ospfd_full() { cli 'show ospf neighbor' | grep -Eq "Full +$1 "; }
ospfd_routes() { local n; n="$(cli 'show route protocol ospf | count' | grep -o '[0-9]\+' | head -1)"; [ "${n:-0}" -ge 250 ]; }
ospfd_via() { docker exec clab-$NAME-ospfd ip route get "$1" | grep -q "via $2 "; }

step "lab folder"
ruby bin/ospfv2 lab new "$DIR" --srlinux
check "the topology and one folder per node" test -f "$DIR/$NAME.clab.yml" -a -f "$DIR/srl/config.cli" -a -d "$DIR/ospfd"

step "images"
[ -z "${SKIP_BUILD:-}" ] && docker build -q -t ospfv2 . >/dev/null
check "ospfv2 image" docker image inspect ospfv2
IMAGE="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).dig("topology", "nodes", "srl", "image")' "$DIR/$NAME.clab.yml")"
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
check "SR Linux image $IMAGE" docker image inspect "$IMAGE"

step "deploy"
(cd "$DIR" && sudo containerlab deploy -t "$NAME.clab.yml") || fail "containerlab deploy"
wait_for 180 "SR Linux answers sr_cli" srl_answers
wait_for 120 "the simulator Full with SR Linux" sim_full
wait_for 90 "ospfd Full with SR Linux" ospfd_full 2.2.2.2

step "routes"
wait_for 90 "ospfd has the simulated area's routes through SR Linux (250 or more)" ospfd_routes
check "ospfd reaches SR Linux's system0 over eth1" ospfd_via 2.2.2.2 10.0.23.1

if [ -n "${SRL_PROBE_DIR:-}" ]; then
  step "what SR Linux answers"
  mkdir -p "$SRL_PROBE_DIR"
  probe() { local f="$1"; shift; { echo "\$ $*"; "$@" 2>&1; } | head -c 6000 >"$SRL_PROBE_DIR/$f.txt"; echo "  $f: $(wc -l <"$SRL_PROBE_DIR/$f.txt") lines"; }
  OSPF='network-instance default protocols ospf instance main'
  probe 01-version sr show version
  probe 02-neighbors sr show network-instance default protocols ospf neighbor
  probe 03-neighbor-json sr "info from state $OSPF area 0.0.0.0 interface ethernet-1/1.0 neighbor * | as json"
  probe 04-interface-json sr "info from state $OSPF area 0.0.0.0 interface * | as json"
  probe 05-routes sr show network-instance default route-table ipv4-unicast summary
  probe 06-routes-json sr "info from state network-instance default route-table ipv4-unicast route 10.255.0.1/32 * * * | as json"
  probe 07-lsdb-json sr "info from state $OSPF area 0.0.0.0 lsdb lsa-types lsa-type 1 | as json"
  probe 08-instance-json sr "info from state $OSPF | as json"
  probe 09-jsonrpc docker exec "$SRL" bash -c "curl -s -m 5 -u 'admin:NokiaSrl1!' http://127.0.0.1/jsonrpc -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"get\",\"params\":{\"commands\":[{\"path\":\"/network-instance[name=default]/protocols/ospf/instance[name=main]/area[area-id=0.0.0.0]/interface[interface-name=ethernet-1/2.0]/neighbor\",\"datastore\":\"state\"}]}}'; echo; which curl jq python3"
  probe 10-config sr info flat network-instance default protocols ospf
fi

echo
echo "${PASSED} checks passed"
