#!/usr/bin/env bash
# The router lab, end to end: what we check by hand in the VM, scripted.
#
#   test/lab/lab_test.sh                 from the repo root, Docker running
#
# It makes a fresh lab folder with "ospfv2 lab new", builds the image,
# brings up sim, frr and ospfd from that folder with docker compose, and
# checks the adjacencies, the routes, saving configurations back to the
# lab folder, and ospfd's event stream. CI runs it on every push; it runs
# the same way in the lab VM.
#
# Environment:
#   LAB_TEST_DIR   where to make the lab folder (default: a new temp dir)
#   SKIP_BUILD=1   use the ospfv2 image already built
#   KEEP_LAB=1     leave the lab running at the end, to look around

set -euo pipefail
cd "$(dirname "$0")/../.."

LAB="${LAB_TEST_DIR:-$(mktemp -d)}/lab"
export LAB
export COMPOSE_PROJECT_NAME=ospfv2
OUT="$(mktemp -d)"
COMPOSE=(docker compose --profile frr --profile ospfd --profile bird)
FAILED=0
STEP=''

# A first commit in the lab folder needs a git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-lab test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-lab-test@localhost}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-lab test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-lab-test@localhost}"

PASSED=0
RESULTS=()
step() { STEP="$*"; echo; echo "=== $*"; }
ok() {
  echo "  ok   $*"
  PASSED=$((PASSED + 1))
  RESULTS+=("| ${STEP} | $* | ok |")
}
fail() {
  echo "  FAIL $*"
  RESULTS+=("| ${STEP} | $* | **FAIL** |")
  FAILED=1
  exit 1
}

# In GitHub Actions: an annotation with the outcome, and the checks as a
# table in the job summary.
report() {
  [ -n "${GITHUB_ACTIONS:-}" ] || return 0
  if ((FAILED)); then
    echo "::error title=Router lab::failed at ${STEP} after ${PASSED} passed checks"
  else
    echo "::notice title=Router lab::${PASSED} checks passed"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo "### Router lab: ${PASSED} passed$( ((FAILED)) && echo ', 1 failed')"
      echo; echo "| Step | Check | Result |"; echo "| --- | --- | --- |"
      printf '%s\n' "${RESULTS[@]}"; } >>"$GITHUB_STEP_SUMMARY"
  fi
}
check() { # check "what" command...
  local what="$1"; shift
  if "$@"; then ok "$what"; else fail "$what"; fi
}

# wait_for SECONDS "what" command...: retries until the command succeeds.
wait_for() {
  local secs="$1" what="$2"; shift 2
  local end=$((SECONDS + secs))
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= end)); then fail "$what (not within ${secs}s)"; fi
    sleep 2
  done
  ok "$what"
}

cli() { # cli "line" "line"...: ospf-cli in the ospfd container, one session
  local args=()
  for l in "$@"; do args+=(-c "$l"); done
  docker compose exec -T ospfd ospf-cli "${args[@]}"
}
vtysh() { docker compose exec -T frr vtysh -c "$*"; }
me() { id -un; }
owner_mode() { stat -c '%U %a' "$1"; }

# Conditions for check and wait_for.
frr_full_with_sim() { vtysh 'show ip ospf neighbor' | grep -q '1.1.1.1.*Full'; }
ospfd_full_with_frr() { cli 'show ospf neighbor' | grep -q '10.99.0.20 .*Full'; }
route_count() { cli 'show route protocol ospf | count' | grep -o '[0-9]\+'; }
routes_installed() { local n; n="$(route_count)"; [ "${n:-0}" -ge 250 ]; }
birdc() { docker compose exec -T bird birdc "$@"; }
bird_full_with_frr() { birdc show ospf neighbors | grep -Eq '^2\.2\.2\.2 .*Full/DR'; }
bird_route_count() { birdc show route protocol ospf1 count | grep -o '^[0-9]\+' | head -1; }
bird_routes() { local n; n="$(bird_route_count)"; [ "${n:-0}" -ge 250 ]; }
bird_in_frr() { vtysh 'show ip ospf neighbor' | grep -q '4\.4\.4\.4'; }
frr_conf_is_ours() { [ "$(owner_mode "$LAB/frr/frr.conf")" = "$(me) 640" ]; }
hostname_is() { [ "$(docker compose exec -T "$1" cat /etc/hostname)" = "$1" ]; }
toggle_link() { curl -fsS -X POST -H 'X-OSPFv2: 1' "http://localhost:8080/api/links/$1/toggle"; }
link_now() { toggle_link "$1" | grep -q "\"up\":$2"; }
spf_changed_routes() { grep -E 'SPF [0-9.]+ ms, [0-9]+ routes, \+[0-9]+ ~[0-9]+ -[0-9]+' "$OUT/spf.txt" | grep -vq '+0 ~0 -0'; }

cleanup() {
  local rc=$?
  ((rc == 0)) || FAILED=1
  report
  if ((FAILED)); then
    echo
    echo "=== failed at: ${STEP}"
    echo "--- ospf-cli: show ospf neighbor"; cli 'show ospf neighbor' 2>&1 || true
    echo "--- frr: show ip ospf neighbor"; vtysh 'show ip ospf neighbor' 2>&1 || true
    echo "--- lab folder"; ls -la "$LAB"/* 2>&1 || true; git -C "$LAB" status --short 2>&1 || true
    echo "--- bird: show ospf neighbors"; birdc show ospf neighbors 2>&1 || true
    for s in sim frr ospfd bird; do echo "--- logs $s (last 40)"; docker compose logs --no-color --tail 40 "$s" 2>&1 || true; done
    for f in "$OUT"/*.txt; do [ -f "$f" ] && { echo "--- $f"; cat "$f"; }; done
  fi
  if [ -z "${KEEP_LAB:-}" ]; then
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  else
    echo "Lab left running from $LAB (export LAB=$LAB to use it)"
  fi
  exit "$rc"
}
trap cleanup EXIT

step "lab folder"
ruby bin/ospfv2 lab new "$LAB"
check "lab.yml and one folder per node" test -f "$LAB/lab.yml" -a -d "$LAB/sim" -a -d "$LAB/frr" -a -d "$LAB/ospfd"
check "a git repository with a first commit" git -C "$LAB" rev-parse --verify -q HEAD
check "nothing uncommitted" test -z "$(git -C "$LAB" status --porcelain)"

step "image"
if [ -z "${SKIP_BUILD:-}" ]; then docker build -q -t ospfv2 . >/dev/null; fi
check "ospfv2 image" docker image inspect ospfv2 >/dev/null

step "lab up"
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d sim frr
wait_for 120 "frr Full with the simulator" frr_full_with_sim
"${COMPOSE[@]}" up -d ospfd
wait_for 120 "ospfd Full with frr" ospfd_full_with_frr
check "hostnames are the service names" hostname_is ospfd
check "frr too" hostname_is frr

step "BIRD, a fourth router"
"${COMPOSE[@]}" up -d --build bird
wait_for 120 "bird Full with frr, the DR" bird_full_with_frr
check "frr sees bird" bird_in_frr
wait_for 60 "bird computes the simulated area's routes (250 or more)" bird_routes
echo "       $(bird_route_count) BIRD routes"

step "routes"
wait_for 90 "ospfd installs the simulated area's routes (250 or more)" routes_installed
echo "       $(route_count) lines of kernel routes"

step "FRR saves into the lab folder"
vtysh 'write memory' >/dev/null
wait_for 15 "frr.conf is ours again, mode 640" frr_conf_is_ours
check "an unchanged FRR gives an unchanged file" git -C "$LAB" diff --quiet -- frr/frr.conf
check "FRR's backup is left out by .gitignore" test -z "$(git -C "$LAB" status --porcelain -- frr)"

step "ospfd saves into the lab folder"
before="$(owner_mode "$LAB/ospfd/ospfd.conf")"
cli configure 'set protocols ospf area 0 interface eth0 metric 5' commit exit >"$OUT/commit.txt"
check "commit complete" grep -q 'commit complete' "$OUT/commit.txt"
diff_lines="$(git -C "$LAB" diff -U0 -- ospfd/ospfd.conf | grep '^[+-][^+-]' || true)"
check "the commit adds exactly the metric line" test "$diff_lines" = '+set protocols ospf area 0.0.0.0 interface eth0 metric 5'
check "ospfd.conf keeps its owner" test "$(stat -c %U "$LAB/ospfd/ospfd.conf")" = "$(me)"
check "and gives others no access" test "$(( 0$(stat -c %a "$LAB/ospfd/ospfd.conf") & 7 ))" -eq 0
cli configure 'delete protocols ospf area 0 interface eth0 metric' commit exit >/dev/null
check "deleting it gives back the same file" git -C "$LAB" diff --quiet -- ospfd/ospfd.conf
check "ospfd's rollbacks are left out by .gitignore" test -z "$(git -C "$LAB" status --porcelain -- ospfd)"
echo "       owner and mode: before $before, after $(owner_mode "$LAB/ospfd/ospfd.conf")"

step "monitor ospf events: a clear"
(timeout 60 docker compose exec -T ospfd ospf-cli -c 'monitor ospf events neighbor' >"$OUT/monitor.txt" 2>&1 &)
wait_for 15 "monitor is watching" grep -q 'Watching neighbor events' "$OUT/monitor.txt"
cli 'clear ospf neighbor' >/dev/null
wait_for 15 "it shows frr going down" grep -q '2.2.2.2@10.99.0.20: full -> down (cleared by operator)' "$OUT/monitor.txt"
wait_for 60 "and coming back to full" grep -Eq '2.2.2.2@10.99.0.20: [a-z_]+ -> full' "$OUT/monitor.txt"
wait_for 60 "ospfd Full with frr again" ospfd_full_with_frr

step "monitor ospf events: SPF after a link change in the simulated area"
(timeout 60 docker compose exec -T ospfd ospf-cli -c 'monitor ospf events spf' >"$OUT/spf.txt" 2>&1 &)
wait_for 15 "monitor is watching" grep -q 'Watching spf events' "$OUT/spf.txt"
check "link 3 down in the simulator" link_now 3 false
wait_for 30 "an SPF run that changes routes" spf_changed_routes
check "link 3 up again" link_now 3 true

step "management API"
api() {
  docker compose exec -T ospfd ruby -rsocket -rjson -e '
    s = UNIXSocket.new("/run/ospfv2/ospfd.sock")
    s.puts({ id: 1, method: "api.info" }.to_json)
    info = JSON.parse(s.gets)["result"]
    s.puts({ id: 2, method: "events.subscribe", params: { since: 0, kinds: ["neighbor", "commit"] } }.to_json)
    sub = JSON.parse(s.gets)["result"]
    evs = Array.new(sub["replayed"]) { JSON.parse(s.gets)["event"] }
    puts JSON.generate(methods: info["methods"], api: info["api"], replayed: sub["replayed"],
                       kinds: evs.map { |e| e["kind"] }.uniq.sort, seq_ordered: evs.map { |e| e["seq"] } == evs.map { |e| e["seq"] }.sort,
                       commit_lines: evs.select { |e| e["kind"] == "commit" }.flat_map { |e| e["data"]["statements"] })'
}
api >"$OUT/api.txt"
check "api.info lists events.subscribe" grep -q '"events.subscribe"' "$OUT/api.txt"
check "replay has neighbor and commit events" grep -q '"kinds":\["commit","neighbor"\]' "$OUT/api.txt"
check "in sequence order" grep -q '"seq_ordered":true' "$OUT/api.txt"
check "the commit event names the statement" grep -q 'interface eth0 metric 5' "$OUT/api.txt"

step "capture and dissect"
# ospfv2 capture in a container sharing FRR's network: real packets from
# FRR, the simulator and ospfd, dissected; a link flap brings updates and acks.
capture() {
  timeout 40 docker run --rm --network container:ospfv2-frr-1 --cap-add NET_RAW --cap-add NET_ADMIN \
    ospfv2:latest capture -c 30 >"$OUT/capture.txt" 2>&1
}
(capture &)
wait_for 20 "the capture starts" grep -q '"capture":{"interface":"eth0"' "$OUT/capture.txt"
sleep 3
toggle_link 3 >/dev/null; sleep 3; toggle_link 3 >/dev/null
wait_for 40 "30 packets" sh -c "[ \$(grep -c '\"packet\"' '$OUT/capture.txt') -ge 30 ]"
dissected() { # every packet: no error, and every byte in a field (bit fields share bytes, never overlap)
  ruby -rjson -e '
    bad = []
    leaves = ->(f) { f["children"] ? f["children"].flat_map { |c| leaves.(c) } : [f] }
    File.readlines(ARGV[0]).map { |l| JSON.parse(l) rescue nil }.compact.select { |m| m["packet"] }.each do |m|
      p = m["packet"]
      bad << "#{p["seq"]} #{p["summary"]}: #{p["errors"].join("; ")}" unless p["errors"].empty?
      bits = Array.new(p["length"], 0)
      over = false
      p["fields"].flat_map { |f| leaves.(f) }.each do |f|
        f["length"].times do |i|
          m8 = f["mask"] ? (f["mask"] >> (8 * (f["length"] - 1 - i))) & 0xff : 0xff
          over ||= (bits[f["offset"] + i] & m8).positive?
          bits[f["offset"] + i] |= m8
        end
      end
      bad << "#{p["seq"]} #{p["summary"]}: bytes not owned or owned twice" if over || bits.any? { |b| b != 0xff }
    end
    puts bad
    exit(bad.empty? ? 0 : 1)' "$OUT/capture.txt"
}
check "every packet dissected, every byte owned" dissected
check "hellos from FRR, the simulator and ospfd" sh -c "grep -q 'Hello 10.99.0.20 ' '$OUT/capture.txt' && grep -q 'Hello 10.99.0.10 ' '$OUT/capture.txt' && grep -q 'Hello 10.99.0.30 ' '$OUT/capture.txt'"
check "LS updates after the flap" grep -q '"summary":"LS Update' "$OUT/capture.txt"
check "and their acks" grep -q '"summary":"LS Ack' "$OUT/capture.txt"
check "LSAs carry their key" grep -q '"lsa":{"type":1,' "$OUT/capture.txt"

echo
echo "=== all checks passed"
