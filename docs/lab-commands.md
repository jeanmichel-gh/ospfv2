# Lab commands

Every command we use to run the router lab and routescope, ready to paste. The [user guide](user-guide.md) explains them; this page is the list. We add to it as the project grows.

A block that starts with `# in the VM` runs in the VM: log in with `ssh ospflab` first. Every other block runs on the Mac.

Paths used here:

| What | Where |
| --- | --- |
| ospfv2 repo | `~/ospfv2` in the VM |
| routescope repo | `~/routescope` in the VM |
| Your lab folder | `~/labs/ospf-lab` in the VM |
| VM files | `~/vms/ospflab` on the Mac |

## The VM

```sh
~/vms/ospflab/start.sh                 # start it; ready in about 20 seconds
ssh ospflab                            # log in
ssh ospflab sudo poweroff              # stop it
```

Ports the Mac forwards to the VM, in the `-nic` line of `~/vms/ospflab/start.sh`:

```sh
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:8080,hostfwd=tcp:127.0.0.1:8081-:8081,hostfwd=tcp:127.0.0.1:8082-:8082 \
```

| Port | What |
| --- | --- |
| 2222 | SSH |
| 8080 | Simulator dashboard, http://localhost:8080 |
| 8081 | Peer dashboard (lab profile) |
| 8082 | routescope, http://localhost:8082 |

A change to `start.sh` takes effect after a restart of the VM:

```sh
ssh ospflab sudo poweroff
sleep 5; ~/vms/ospflab/start.sh
```

## Set LAB once

Compose finds your lab folder through `LAB`. Put it in `~/.bashrc` so every login has it:

```sh
# in the VM
grep -q 'export LAB=' ~/.bashrc || echo 'export LAB=~/labs/ospf-lab' >> ~/.bashrc
source ~/.bashrc; echo "$LAB"
```

Make the lab folder before anything uses `LAB`. If compose runs first, Docker creates the folder itself: empty, owned by root, and FRR stops with `/etc/frr/daemons does not exist`. Once:

```sh
# in the VM
cd ~/ospfv2
mkdir -p ~/labs && sudo chown $USER: ~/labs
[ -f ~/labs/ospf-lab/lab.yml ] && echo "lab folder ok" || bin/ospfv2 lab new ~/labs/ospf-lab
```

To make it again from the template (the old one is kept aside, nothing is deleted):

```sh
# in the VM
cd ~/ospfv2
docker compose --profile frr --profile ospfd --profile bird down
cd ~/routescope && docker compose down && cd ~/ospfv2
sudo chown $USER: ~/labs
sudo mv ~/labs/ospf-lab ~/labs/ospf-lab.old-$(date +%Y%m%d%H%M)
bin/ospfv2 lab new ~/labs/ospf-lab
```

## Get the code: a branch, or the latest

Set the branch of each repo you want to run, then paste the whole block. It fetches, switches, pulls, rebuilds both images, and brings everything up again from zero. `master` and `main` are the default branches; a pull request's branch name is at the top of its page on GitHub.

```sh
# in the VM
OSPFV2_BRANCH=master            # or a branch, e.g. lab-commands
ROUTESCOPE_BRANCH=main          # or a branch, e.g. lab-missing

cd ~/ospfv2
git fetch origin && git switch "$OSPFV2_BRANCH" && git pull --ff-only
docker build -t ospfv2 .

cd ~/routescope
git fetch origin && git switch "$ROUTESCOPE_BRANCH" && git pull --ff-only
docker compose build

cd ~/ospfv2
docker compose --profile frr --profile ospfd --profile bird down
docker compose --profile frr up -d sim frr
full=; for i in $(seq 45); do docker compose exec -T frr vtysh -c 'show ip ospf neighbor' </dev/null 2>/dev/null | grep -q '1\.1\.1\.1.*Full' && full=1 && break; sleep 2; done; [ "$full" ] && echo sim Full || docker compose logs --tail 40 frr
docker compose up -d ospfd
cd ~/routescope && docker compose up -d --force-recreate
sleep 3; curl -s --max-time 5 localhost:8082/api/health; echo
cd ~/ospfv2 && git log --oneline -1 && cd ~/routescope && git log --oneline -1
```

The last line shows the commit each repo runs. `git pull --ff-only` refuses when you have local changes to a file the branch changes; `git status` shows them and `git stash` puts them aside.

A branch that was force pushed (rebased) does not pull. Reset it to GitHub's copy, which drops any local commits on it:

```sh
# in the VM, in the repo
git fetch origin && git reset --hard "origin/$(git branch --show-current)"
```

First time only, to get routescope:

```sh
# in the VM
cd ~ && git clone https://github.com/jeanmichel-gh/routescope.git
```

## Start everything after a VM boot

The lab containers do not restart by themselves. routescope does: Docker starts it again at boot. The quickest way: open http://localhost:8082, click the lab name in the header, and Start. routescope serves every lab in `~/labs` and runs compose labs from `~/ospfv2`.

From the shell instead: start the simulator and FRR, wait until they are Full, then ospfd:

```sh
# in the VM
cd ~/ospfv2
docker compose --profile frr up -d sim frr
full=; for i in $(seq 45); do docker compose exec -T frr vtysh -c 'show ip ospf neighbor' </dev/null 2>/dev/null | grep -q '1\.1\.1\.1.*Full' && full=1 && break; sleep 2; done; [ "$full" ] && echo sim Full || docker compose logs --tail 40 frr
docker compose up -d ospfd
docker compose --profile bird up -d --build bird
cd ~/routescope && docker compose up -d
curl -s --max-time 5 localhost:8082/api/health; echo
```

The wait gives up after about 90 seconds and shows FRR's last log lines. Then open http://localhost:8082 on the Mac.

## Restart

Everything, lab and routescope:

```sh
# in the VM
cd ~/ospfv2
docker compose --profile frr --profile ospfd --profile bird down
docker compose --profile frr up -d sim frr
full=; for i in $(seq 45); do docker compose exec -T frr vtysh -c 'show ip ospf neighbor' </dev/null 2>/dev/null | grep -q '1\.1\.1\.1.*Full' && full=1 && break; sleep 2; done; [ "$full" ] && echo sim Full || docker compose logs --tail 40 frr
docker compose up -d ospfd
docker compose --profile bird up -d --build bird
cd ~/routescope && docker compose restart
```

One node at a time:

```sh
# in the VM, from ~/ospfv2
docker compose restart ospfd
docker compose restart frr
docker compose restart sim                     # also fixes a simulator stuck in ExStart
docker compose restart bird
```

routescope only:

```sh
# in the VM
cd ~/routescope && docker compose restart
```

## Stop

```sh
# in the VM
cd ~/routescope && docker compose down
cd ~/ospfv2 && docker compose --profile frr --profile ospfd --profile bird down
```

`down` keeps the lab folder. Your saved configurations stay.

## BIRD

BIRD 2 is a fourth router on the segment, 4.4.4.4 at 10.99.0.40, priority 0 so FRR stays the DR. Its configuration is `$LAB/bird/bird.conf`. A lab made before BIRD needs the folder and the node once:

```sh
# in the VM
cp -r ~/ospfv2/examples/lab/bird $LAB/
grep -q 'kind: bird' $LAB/lab.yml || sed -i 's/^  - name: ospfd$/  - name: bird\n    kind: bird\n    service: bird\n    profiles: [bird]\n    address: 10.99.0.40\n    config: bird\/bird.conf\n\n  - name: ospfd/' $LAB/lab.yml
cd $LAB && git add bird lab.yml && git commit -m 'BIRD, a fourth router'
```

Look at it, and load an edited file:

```sh
# in the VM, from ~/ospfv2
docker compose exec bird birdc show ospf neighbors
docker compose exec bird birdc show route protocol ospf1 count
docker compose exec bird birdc configure
```

## The containerlab lab

A second lab, on containerlab: the simulated area behind FRR, and a ring of point-to-point links between FRR, ospfd and BIRD. A link can fail and ospfd go the other way round. Install containerlab and build the images once:

```sh
# in the VM
bash -c "$(curl -sL https://get.containerlab.dev)"
cd ~/ospfv2 && docker build -t ospfv2 . && docker compose --profile bird build bird
docker pull quay.io/frrouting/frr:10.2.1
```

Make it:

```sh
# in the VM
cd ~/ospfv2 && bin/ospfv2 lab new ~/labs/ospf-ring --containerlab
```

Then start it from routescope: click the lab name in the header, pick ospf-ring, Start. Stop the compose lab first if you want only one running; the two can run side by side. From the shell instead:

```sh
# in the VM
cd ~/labs/ospf-ring && sudo containerlab deploy -t ospf-ring.clab.yml
```

Look at it, fail a link by hand, take it down:

```sh
# in the VM
docker exec clab-ospf-ring-ospfd ospf-cli -c 'show ospf neighbor'
docker exec clab-ospf-ring-frr ip link set eth2 down; sleep 10; docker exec clab-ospf-ring-ospfd ip route get 2.2.2.2
docker exec clab-ospf-ring-frr ip link set eth2 up
cd ~/labs/ospf-ring && sudo containerlab destroy -t ospf-ring.clab.yml
```

routescope finds a new lab folder in `~/labs` within seconds; open it from the Labs panel. Labs somewhere else, or ospfv2 checked out somewhere else:

```sh
# in the VM
cd ~/routescope && LABS=~/work/labs OSPFV2=~/src/ospfv2 docker compose up -d
```

## The SR Linux lab

Nokia SR Linux, a vendor router, free from Nokia: the simulated area behind it on a LAN, and ospfd on a point-to-point link behind it. It needs about 2 GB of memory while running, and its image has an ARM64 build. Pull the image and make the lab once:

```sh
# in the VM
docker pull ghcr.io/nokia/srlinux:26.3.1
cd ~/ospfv2 && bin/ospfv2 lab new ~/labs/ospf-srl --srlinux
```

Then start it from routescope's lab menu. It boots in about a minute. Look at it from the shell:

```sh
# in the VM
docker exec clab-ospf-srl-srl sr_cli show network-instance default protocols ospf neighbor
docker exec clab-ospf-srl-srl sr_cli show network-instance default route-table
docker exec -it clab-ospf-srl-srl sr_cli                    # its CLI; quit to leave
docker exec clab-ospf-srl-ospfd ospf-cli -c 'show ospf neighbor'
```

Its configuration is `~/labs/ospf-srl/srl/config.cli`: `set` lines applied when it boots. Its ports are `ethernet-1/1` and `ethernet-1/2` in its CLI, `e1-1` and `e1-2` for Linux and routescope's link faults.

## Check

```sh
# in the VM, from ~/ospfv2
docker compose ps
docker compose exec frr vtysh -c 'show ip ospf neighbor'
docker compose exec ospfd ospf-cli -c 'show ospf neighbor'
docker compose exec ospfd ospf-cli -c 'show ospf overview'
docker compose logs --tail 50 ospfd
```

routescope's view of the lab:

```sh
# in the VM
curl -s --max-time 5 localhost:8082/api/health; echo
curl -s --max-time 5 localhost:8082/api/labs/ospf-lab/nodes | ruby -rjson -e 'JSON.parse($stdin.read).each { |n| puts [n["name"], n["health"], n["reason"]].compact.join("  ") }'
cd ~/routescope && docker compose logs --tail 50
```

## Query the lab from the shell

Through routescope's API, the same way for every lab (compose or containerlab) and every router (FRR, ospfd, BIRD, SR Linux, the simulator). Paste the helpers once per shell, then any block below. `L` is the lab's name as the lab menu shows it; a lab that is not running answers with its error (`routescope: sim is not running`).

```sh
# in the VM: the helpers
rs() { curl -s --max-time 60 "localhost:8082/api/$1"; }
py() { python3 -c "import json, sys
t = sys.stdin.read()
if not t.strip(): sys.exit('routescope: no answer (is it up? curl -s localhost:8082/api/health)')
d = json.loads(t)
if isinstance(d, dict) and 'error' in d: sys.exit('routescope: ' + d['error'])
$1"; }
L=ospf-lab
```

The labs, and which run:

```sh
# in the VM
rs labs | py 'for l in d: print(l["id"], l.get("runtime",""), l.get("state",""), (l.get("job") or {}).get("action",""))'
```

Every node, its router id and its neighbors:

```sh
# in the VM
rs labs/$L/nodes | py '
for n in d:
    o = n.get("ospf") or {}
    print(n["name"], n["kind"], n["health"], o.get("router_id") or "", n.get("reason") or "")
    for x in o.get("neighbors", []): print("   ", x["router_id"], x.get("address") or "", x["state"], x.get("role") or "")'
```

One node's table: `neighbors`, `interfaces`, `lsdb` or `routes`.

```sh
# in the VM
N=frr; T=neighbors
rs labs/$L/nodes/$N/tables/$T | py '
print(len(d["rows"]), "rows")
for r in d["rows"][:5]: print(" ", r)'
```

How many routes a node has, and one of them; its LSAs by type:

```sh
# in the VM
N=frr; P=10.255.0.1/32
rs labs/$L/nodes/$N/tables/routes | py "r = d['rows']; print(len(r), 'routes'); print([x for x in r if x['prefix'] == '$P'])"
rs labs/$L/nodes/$N/tables/lsdb | py 'from collections import Counter; print(Counter(r["type_name"] for r in d["rows"]))'
```

The simulator's links: their metric, up or down, and its neighbor:

```sh
# in the VM
rs labs/$L/nodes/sim/area | py '
down = [l for l in d["links"] if not l["up"]]
print(len(d["links"]), "links,", len(down), "down; neighbor", (d.get("neighbor") or {}).get("state"))
for l in d["links"][:10]: print("  #%s %s metric %s %s" % (l["id"], l["name"], l["metric"], "up" if l["up"] else "DOWN"))'
```

One simulated link, as its list says it and as its map draws it (both should show the same metric):

```sh
# in the VM
ID=1
rs labs/$L/nodes/sim/area | py "print('link', [l for l in d['links'] if l['id'] == $ID]); print('map ', [e for e in d['edges'] if e.get('id') == $ID])"
```

The routers compared: LSAs and routes, and what differs:

```sh
# in the VM
rs labs/$L/compare/lsdb | py '
print("lsdb", d["counts"])
for l in [x for x in d["lsas"] if x["status"] != "same"][:10]: print("  ", l["key"], l["status"], "; ".join(l["reasons"]))'
rs labs/$L/compare/routes | py '
print("routes", d["counts"])
for r in [x for x in d["routes"] if x["status"] == "missing"][:10]: print("  ", r["prefix"], "; ".join(r["reasons"]))'
```

Routes "differ" by cost and next hop between routers; that is normal. "missing" is not.

The last start or stop of a lab, with what it printed:

```sh
# in the VM
rs labs/$L/lifecycle | py '
j = d.get("job") or {}
print(d["state"], "running:", ", ".join(d["up"]))
print(j.get("action"), j.get("state"), j.get("error") or "")
print("\n".join(j.get("output", [])[-20:]))'
```

What was done to the labs, newest first:

```sh
# in the VM
rs labs/$L/audit | py 'for a in d[:10]: print(a["time"], a["user"], a["action"], {k: v for k, v in a.items() if k not in ("time", "user", "action")})'
```

### Straight to a router

A compose lab's containers are `ospfv2-NODE-1`; a containerlab lab's are `clab-LAB-NODE`.

```sh
# in the VM
docker exec ospfv2-frr-1 vtysh -c 'show ip ospf neighbor'
docker exec ospfv2-ospfd-1 ospf-cli -c 'show ospf neighbor'
docker exec ospfv2-bird-1 birdc show ospf neighbors
docker exec clab-ospf-srl-srl sr_cli show network-instance default protocols ospf neighbor
docker exec clab-ospf-ring-sim ruby -rnet/http -e 'puts Net::HTTP.get(URI("http://127.0.0.1:8080/api/state"))' | head -c 400; echo
```

### A lab container on an old image

A rebuilt image reaches a lab only when its containers are made again (Stop and Start the lab). A container older than its image runs the old code:

```sh
# in the VM
for c in $(docker ps --format '{{.Names}}' | grep -E '^(ospfv2-|clab-)'); do
  img=$(docker inspect -f '{{.Config.Image}}' "$c")
  [ "$(docker inspect -f '{{.Image}}' "$c")" = "$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null)" ] && s=current || s=OLD
  echo "$c  $img  $s"
done
```

## Use the routers

```sh
# in the VM, from ~/ospfv2
docker compose exec ospfd ospf-cli             # ospfd's CLI
docker compose exec frr vtysh                  # FRR's CLI
docker compose exec ospfd ospf-cli -c 'monitor ospf events'   # live events, Ctrl-C to stop
```

Or from routescope: the buttons on each node open the same terminals in tabs.

## Save configurations

`commit` in ospf-cli and `write memory` in vtysh write to the lab folder. Keep what you want in git:

```sh
# in the VM
cd $LAB && git status && git diff
git add -A && git commit -m 'what changed'
```

The lab folder's commits are signed `lab <lab@configs>`, set in that repository only by `lab new`. A lab folder made before that needs it once:

```sh
# in the VM
cd $LAB && git config user.name lab && git config user.email lab@configs
```

## Recordings

routescope's Record button keeps events, logs, packets and before and after snapshots in `$LAB/recordings/`. Git ignores that folder. The first recording adds it to `$LAB/.gitignore`; commit that change once.

```sh
# in the VM
ls -lt $LAB/recordings
cat $LAB/recordings/*/meta.json | head -40
du -sh $LAB/recordings
```

Delete a recording from the Recordings panel, or by hand:

```sh
# in the VM
rm -rf $LAB/recordings/RECORDING_ID
```

## Scenarios

Scenarios are YAML files in `$LAB/scenarios/`, kept in the lab's git. A new lab gets two examples. To add them to a lab made before:

```sh
# in the VM
mkdir -p $LAB/scenarios && cp ~/ospfv2/examples/lab/scenarios/*.yml $LAB/scenarios/
cd $LAB && git add scenarios && git commit -m 'Example scenarios'
```

Run one without the page, and read how it went:

```sh
# in the VM
curl -s -X POST -H 'X-Routescope: 1' localhost:8082/api/labs/ospf-lab/scenarios/edge-down/run; echo
sleep 30; curl -s localhost:8082/api/labs/ospf-lab/scenarios/runs/current | ruby -rjson -e 'r = JSON.parse($stdin.read); puts r["result"], r["measures"], r["steps"].map { "#{_1["result"]} #{_1["name"]}" }'
```

The format: routescope `docs/scenarios.md`.

## Run the tests in the VM

The ospfv2 lab test makes its own lab folder and brings up its own lab, so it replaces the lab you are running. Start yours again afterwards.

```sh
# in the VM
cd ~/ospfv2 && test/lab/lab_test.sh
```

routescope's end-to-end test, against the running lab and routescope:

```sh
# in the VM
cd ~/routescope && ROUTESCOPE_URL=http://127.0.0.1:8082 ruby test/e2e/lab_test.rb
```

## Troubleshooting

Blocks we used to find out what was wrong. Each one only looks; none changes anything unless it says so. Paste the whole output when asking for help.

### The lab folder

Which folder compose uses, who owns it, and what is in it. Everything should belong to you, and `frr/` should hold `daemons`. A folder owned by root was made by Docker, not by `lab new`; see "Set LAB once" to make it again.

```sh
# in the VM
echo "LAB=$LAB"
ls -la ~/labs $LAB $LAB/frr $LAB/ospfd
cd $LAB && git status --short && git log --format='%h %an / %cn  %s' -5
```

### What a container really mounted

The folders a container got, and whether it can write them. Compare with `$LAB`.

```sh
# in the VM
docker inspect ospfv2-frr-1 -f '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{println}}{{end}}'
docker inspect ospfv2-ospfd-1 -f '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{println}}{{end}}'
docker inspect routescope-routescope-1 -f '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{println}}{{end}}'
```

### A container that stops or restarts

Its state and its last log lines say why: a missing file, a bad configuration.

```sh
# in the VM
cd ~/ospfv2 && docker compose ps -a
docker compose logs --tail 40 frr
docker compose logs --tail 40 ospfd
docker compose logs --tail 40 sim
```

### Which code runs

The commit each repo is on, and when each container was made. A container older than your last `git pull` runs the old code: rebuild it ("Get the code").

```sh
# in the VM
cd ~/ospfv2 && git log --oneline -1 && docker compose ps
cd ~/routescope && git log --oneline -1 && docker compose ps
docker images --format '{{.Repository}}:{{.Tag}}  {{.CreatedSince}}' | grep -E 'ospfv2|routescope'
```

### routescope

What routescope sees, piece by piece. `problems` in the health answer says what keeps a lab from loading.

```sh
# in the VM
curl -s --max-time 5 localhost:8082/api/health; echo
curl -s --max-time 5 localhost:8082/api/labs/ospf-lab/nodes | ruby -rjson -e 'JSON.parse($stdin.read).each { |n| puts [n["name"], n["health"], n["reason"]].compact.join("  ") }'
curl -s --max-time 10 localhost:8082/api/labs/ospf-lab/config | ruby -rjson -e 'o=JSON.parse($stdin.read); p o["git"]; o["nodes"].each { |n| p n.slice("node","saved","git","error") }'
curl -s --max-time 5 localhost:8082/api/labs/ospf-lab/audit | ruby -rjson -e 'JSON.parse($stdin.read).last(10).each { |e| puts e.values_at("time","user","action","node").compact.join("  ") }'
cd ~/routescope && docker compose logs --tail 50
```

One table of one router, as the inspector gets it (tables: neighbors, interfaces, lsdb, routes):

```sh
# in the VM
curl -s --max-time 10 localhost:8082/api/labs/ospf-lab/nodes/frr/tables/neighbors | ruby -rjson -e 'JSON.parse($stdin.read)["rows"].each { |r| p r }'
```

The tools routescope needs inside its container: git, and setpriv to run git as the lab folder's owner. `command -v` in `sh` only reports its first name, so ask for each.

```sh
# in the VM
docker exec routescope-routescope-1 sh -c 'command -v git; command -v setpriv; command -v docker; id'
```

### Do it without the page

The same actions the page takes, straight through the API. When the page seems to do nothing, these show the server's answer or its error.

```sh
# in the VM: commit the lab's changed files (this changes your lab's git history)
curl -s -X POST -H 'X-Routescope: 1' -H 'Content-Type: application/json' \
  -d '{"message":"frr: test commit from curl"}' localhost:8082/api/labs/ospf-lab/config/commit; echo

# FRR writes its running configuration to its file (write memory)
curl -s -X POST -H 'X-Routescope: 1' localhost:8082/api/labs/ospf-lab/config/frr/save; echo

# take a simulated link down, then up again (link 1)
curl -s -X POST -H 'X-Routescope: 1' -H 'Content-Type: application/json' -d '{"link":1}' localhost:8082/api/labs/ospf-lab/nodes/sim/area/link.down; echo
curl -s -X POST -H 'X-Routescope: 1' -H 'Content-Type: application/json' -d '{"link":1}' localhost:8082/api/labs/ospf-lab/nodes/sim/area/link.up; echo
```

### Known problems and their fixes

| What you see | Why | Fix |
| --- | --- | --- |
| FRR stops at once: `/etc/frr/daemons does not exist` | `LAB` names a folder Docker made, empty and owned by root | Make it again: "Set LAB once" |
| `lab new`: cannot make the lab folder | `~/labs` belongs to root | `sudo chown $USER: ~/labs` |
| compose: `bind source path does not exist` | `LAB` names a folder that does not exist | `bin/ospfv2 lab new $LAB` |
| The page hangs, `curl` to 8082 hangs | routescope cannot load the lab and restarts | `docker compose logs` in `~/routescope`; health says why |
| The wait for Full never ends | FRR stopped | `docker compose logs --tail 40 frr` |
| Simulator loops between ExStart and Exchange | ospfd came up before the simulator was Full | `docker compose restart sim` |
| `git` in the lab folder: permission denied on `frr/frr.conf` | FRR saved it moments ago | Wait 2 seconds; its start script gives it back |
| Lab commit failed: needs `user.name` | A lab folder made before `lab new` set its identity | `cd $LAB && git config user.name lab && git config user.email lab@configs` |
