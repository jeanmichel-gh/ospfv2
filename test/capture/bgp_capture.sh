#!/usr/bin/env bash
# Prints what FRR and BIRD answer to every command routescope's BGP
# drivers send, from the ospf-bgp lab, so routescope's unit test fixtures
# are real output and not invented. It lives here because the lab does and
# because this repository's CI runs it (.github/workflows/capture.yml); the
# output goes to the job log, one block per command:
#
#   ===== r1 vtysh show bgp summary json
#   ...the answer...
#
# routescope's test/capture/extract.rb turns a saved log back into fixture
# files.
#
# Before capturing it changes the running lab, not its files, so the
# output has what the panes need to show:
#   - asbr tags what it sends r1 with standard, extended and large
#     communities;
#   - r1 keeps what asbr sends before policy (soft reconfiguration
#     inbound), and r2 does not, so both answers are captured;
#   - r2 (FRR) and r3 (BIRD) both originate 172.16.9.0/24, so r1 holds two
#     paths to it and says why one won;
#   - the r1 to asbr session is flapped once, so the flap counters move.
#
#   LAB=ospf-bgp test/capture/bgp_capture.sh
set -uo pipefail
LAB="${LAB:-ospf-bgp}"

ex() { docker exec "clab-$LAB-$1" "${@:2}"; }
vt() { ex "$1" vtysh -c "$2"; }
cfg() { local n="$1"; shift; local a=(); for l in "$@"; do a+=(-c "$l"); done; ex "$n" vtysh -c 'configure terminal' "${a[@]}" >/dev/null; }
show() { echo "===== $1 ${*:2}"; ex "$1" "${@:2}" 2>&1; echo; }
vshow() { echo "===== $1 vtysh $2"; vt "$1" "$2" 2>&1; echo; }
bshow() { echo "===== $1 birdc $2"; ex "$1" birdc "$2" 2>&1; echo; }

echo "### versions"
vshow r1 'show version'
bshow r3 'show status'

echo "### changing the running lab"
cfg asbr 'route-map TAG permit 10' 'set community 65000:100 65000:200 additive' \
  'set large-community 65000:1:1' 'set extcommunity rt 65000:7' 'exit' \
  'router bgp 65000' 'address-family ipv4 unicast' 'neighbor 10.1.100.2 route-map TAG out' \
  'neighbor 10.1.100.2 send-community all'
cfg r1 'router bgp 65001' 'address-family ipv4 unicast' 'neighbor 10.1.100.1 soft-reconfiguration inbound' \
  'neighbor 10.1.12.2 send-community all' 'neighbor 10.1.13.2 send-community all'
cfg r2 'ip route 172.16.9.0/24 blackhole' 'router bgp 65001' 'address-family ipv4 unicast' 'network 172.16.9.0/24'
ex r3 sh -c 'sed -i "s#route 192.168.3.0/24 blackhole;#route 192.168.3.0/24 blackhole;\n  route 172.16.9.0/24 blackhole;#" /etc/bird/bird.conf'
ex r3 birdc configure
vt asbr 'clear bgp 10.1.100.2 soft out' >/dev/null
sleep 20

echo "### FRR"
for n in r1 r2; do
  vshow $n 'show bgp summary json'
  vshow $n 'show bgp neighbors json'
  vshow $n 'show bgp ipv4 unicast json'
  vshow $n 'show bgp ipv4 unicast detail json'
  vshow $n 'show bgp ipv4 unicast json detail'
  vshow $n 'show bgp ipv4 unicast 172.16.9.0/24 json'
  vshow $n 'show bgp ipv4 unicast 10.255.0.1/32 json'
done
vshow r1 'show bgp ipv4 unicast neighbors 10.1.100.1 received-routes json'
vshow r1 'show bgp ipv4 unicast neighbors 10.1.100.1 routes json'
vshow r1 'show bgp ipv4 unicast neighbors 10.1.100.1 advertised-routes json'
vshow r1 'show bgp ipv4 unicast neighbors 10.1.12.2 advertised-routes json'
vshow r2 'show bgp ipv4 unicast neighbors 10.1.12.1 received-routes json'
vshow r2 'show bgp ipv4 unicast neighbors 10.1.12.1 routes json'

echo "### BIRD"
for c in 'show protocols all' 'show route all' 'show route all where source = RTS_BGP' \
  'show route all protocol r1' 'show route all export r1' 'show route all exported r1' \
  'show route all for 172.16.9.0/24' 'show route all for 10.255.0.1/32' \
  'show route all 172.16.9.0/24' 'show route count'; do
  bshow r3 "$c"
done

echo "### a flap of r1 to asbr"
ex r1 ip link set eth3 down; sleep 15; ex r1 ip link set eth3 up; sleep 25
vshow r1 'show bgp summary json'
vshow r1 'show bgp neighbors 10.1.100.1 json'
ex r3 birdc 'disable r1' >/dev/null; sleep 3; ex r3 birdc 'enable r1' >/dev/null; sleep 15
bshow r3 'show protocols all r1'
echo "### done"
