#!/usr/bin/env bash
# The BFD interop lab, routescope/labs/ospf-bfd, and its gate: ospfd and
# FRR on one link, BFD Up on both and the neighbor Full; then 100% loss
# on the link with netem, and the neighbor Down in under a second on
# both, with "BFD down" on ospfd. Then the link back, and Full again.
# Needs containerlab, sudo, and bfd4r beside this repository (../bfd4r).
# KEEP_LAB=1 leaves the lab up. IMAGE=ospfv2:mine builds and runs that
# tag instead of ospfv2:latest, leaving other labs' image alone.
#
#   test/lab/bfd_test.sh            from the ospfv2 folder
set -uo pipefail
cd "$(dirname "$0")/../.."

DIR="${BFD_TEST_DIR:-$(mktemp -d)}/ospf-bfd"
NAME=ospf-bfd
LIMIT_MS=1000
IMAGE="${IMAGE:-ospfv2:latest}"
PASSED=0
STEP=''

step() { STEP="$*"; echo; echo "=== $*"; }
ok() { echo "  ok   $*"; PASSED=$((PASSED + 1)); }
fail() {
  echo "  FAIL $*"
  local diag
  diag="$( {
    echo "--- frr"; docker exec clab-$NAME-frr vtysh -c 'show ip ospf neighbor' -c 'show bfd peers'
    echo "--- ospfd"; docker exec clab-$NAME-ospfd ospf-cli -c 'show ospf neighbor | display json'
    docker exec clab-$NAME-ospfd ospf-cli -c 'show ospf events | last 30'
    echo "--- bfdd4r"; docker exec clab-$NAME-ospfd bfd4r-cli show.sessions
    docker exec clab-$NAME-ospfd tail -20 /var/log/bfdd4r.log
    for n in frr ospfd; do echo "--- logs $n"; docker logs --tail 30 clab-$NAME-$n; done
  } 2>&1 )"
  echo "$diag"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error title=BFD lab::failed at ${STEP}: $* (after ${PASSED} passed checks)"
    echo "::error title=BFD lab state::$(echo "$diag" | tail -n 120 | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')"
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
# netem on a node's eth1, with the host's tc in the node's network
# namespace: quicker than containerlab tools netem, so the loss starts
# within a few milliseconds of T0.
netem() {
  local pid; pid=$(docker inspect -f '{{.State.Pid}}' "clab-$NAME-$1")
  if [ "$2" = 0 ]; then sudo nsenter -t "$pid" -n tc qdisc del dev eth1 root
  else sudo nsenter -t "$pid" -n tc qdisc replace dev eth1 root netem loss "$2%"; fi
}
cleanup() {
  local rc=$?
  if [ -z "${KEEP_LAB:-}" ] && [ -f "$DIR/$NAME.clab.yml" ]; then
    (cd "$DIR" && sudo containerlab destroy -t "$NAME.clab.yml" --cleanup >/dev/null 2>&1) || true
  fi
  [ -n "${GITHUB_ACTIONS:-}" ] && ((rc == 0)) && echo "::notice title=BFD lab::${PASSED} checks passed${RESULT:+; $RESULT}"
  exit $rc
}
trap cleanup EXIT

vtysh() { docker exec clab-$NAME-frr vtysh -c "$*"; }
cli() { docker exec clab-$NAME-ospfd ospf-cli -c "$*"; }
# ospfd's neighbor 2.2.2.2, one field of its row in show.neighbors.
nbr() { cli 'show ospf neighbor | display json' | ruby -rjson -e 'n = JSON.parse($stdin.read).find { _1["router_id"] == "2.2.2.2" }; puts n && n[ARGV[0]]' "$1"; }
frr_full() { vtysh 'show ip ospf neighbor' | grep -Eq '^1\.1\.1\.1 .*Full'; }
frr_down() { ! vtysh 'show ip ospf neighbor' | grep -Eq '^1\.1\.1\.1 '; }
frr_bfd_up() { vtysh 'show bfd peers' | grep -A12 'peer 10.0.12.1 ' | grep -q 'Status: up'; }
ospfd_full() { [ "$(nbr state)" = full ]; }
ospfd_bfd_up() { [ "$(nbr bfd)" = up ]; }
# ospfd's neighbor events, replayed from its API: times to the millisecond.
neighbor_events() {
  docker exec clab-$NAME-ospfd ruby -rsocket -rjson -e '
    s = UNIXSocket.new("/run/ospfv2/ospfd.sock")
    s.puts JSON.generate(id: 1, method: "events.subscribe", params: { kinds: ["neighbor"], since: 0 })
    out = []
    while IO.select([s], nil, nil, 1) && (line = s.gets)
      m = JSON.parse(line)
      out << m["event"] if m["event"]
    end
    puts JSON.generate(out)'
}
# Milliseconds since the epoch, from the host clock the containers share.
now_ms() { date +%s%3N; }

step "lab folder"
mkdir -p "$(dirname "$DIR")"
cp -r routescope/labs/$NAME "$DIR"
sed -i "s|image: ospfv2:latest|image: $IMAGE|" "$DIR/$NAME.clab.yml"
check "the topology and one folder per node" test -f "$DIR/$NAME.clab.yml" -a -d "$DIR/frr" -a -d "$DIR/ospfd"

step "images"
if [ -z "${SKIP_BUILD:-}" ]; then
  docker build -q -t "$IMAGE" --build-context bfd4r="${BFD4R:-../bfd4r}" . >/dev/null || fail "docker build"
fi
check "ospfv2 image" docker image inspect "$IMAGE"
check "bfdd4r in it" docker run --rm --entrypoint sh "$IMAGE" -c 'command -v bfdd4r && command -v with-bfdd4r'

step "deploy"
(cd "$DIR" && sudo containerlab deploy -t "$NAME.clab.yml") || fail "containerlab deploy"
wait_for 90 "ospfd Full with FRR" ospfd_full
wait_for 30 "FRR Full with ospfd" frr_full
wait_for 30 "BFD Up on ospfd" ospfd_bfd_up
wait_for 30 "BFD Up on FRR" frr_bfd_up
check "bfdd4r has the session, client ospfd" sh -c "docker exec clab-$NAME-ospfd bfd4r-cli show.sessions | grep -q ospfd"

step "the link fails: 100% loss with netem on both ends"
sudo true # sudo's prompt, if any, before the clock starts
T0=$(now_ms)
netem ospfd 100 & netem frr 100 & wait
echo "  loss on both ends $(( $(now_ms) - T0 )) ms after T0"
# Each side's Down, by its own clock: polled here every 50 ms, so the
# figure is at most 50 ms late, plus one docker exec.
FRR_MS='' ; OSPFD_MS=''
end=$((SECONDS + 15))
while { [ -z "$FRR_MS" ] || [ -z "$OSPFD_MS" ]; } && ((SECONDS < end)); do
  [ -z "$OSPFD_MS" ] && [ "$(nbr state)" = "" ] && OSPFD_MS=$(( $(now_ms) - T0 ))
  [ -z "$FRR_MS" ] && frr_down && FRR_MS=$(( $(now_ms) - T0 ))
  sleep 0.05
done
[ -n "$OSPFD_MS" ] || fail "ospfd's neighbor did not go Down"
[ -n "$FRR_MS" ] || fail "FRR's neighbor did not go Down"
# ospfd's own record of it: the neighbor event's time, to the millisecond.
EVENT=$(neighbor_events | ruby -rjson -rtime -e '
  t0 = ARGV[0].to_i
  ms = ->(e) { (Time.iso8601(e["time"]).to_f * 1000).round - t0 }
  e = JSON.parse($stdin.read).find { _1.dig("data", "to") == "down" && ms.(_1) >= 0 }
  puts e ? [e.dig("data", "event"), ms.(e)].join(" ") : "none -1"' "$T0")
echo "  ospfd's neighbor Down after ${OSPFD_MS} ms (polled), event: ${EVENT}; FRR's after ${FRR_MS} ms (polled)"
check "ospfd's neighbor event says BFD down" test "${EVENT% *}" = "BFD down"
EVENT_MS=${EVENT##* }
check "ospfd's neighbor Down in under a second (${EVENT_MS} ms, by its event)" test "$EVENT_MS" -lt $LIMIT_MS
check "FRR's neighbor Down in under a second (${FRR_MS} ms, polled)" test "$FRR_MS" -lt $LIMIT_MS
# FRR's daemons do not log to the container's output, so FRR's reason is
# not read here: Down in under a second, with hellos every 2 s and a dead
# interval of 8 s, can only be BFD.
RESULT="neighbor Down: ospfd ${EVENT_MS} ms (event), FRR ${FRR_MS} ms (polled)"

step "the link back"
netem ospfd 0 & netem frr 0 & wait
wait_for 60 "ospfd Full again" ospfd_full
wait_for 30 "FRR Full again" frr_full
wait_for 30 "BFD Up again on ospfd" ospfd_bfd_up
wait_for 30 "BFD Up again on FRR" frr_bfd_up

echo
echo "${PASSED} checks passed; ${RESULT}"
