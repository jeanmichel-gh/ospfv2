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
docker compose --profile frr --profile ospfd down
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
docker compose --profile frr --profile ospfd down
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

The lab containers do not restart by themselves. routescope does: Docker starts it again at boot. Start the simulator and FRR, wait until they are Full, then ospfd:

```sh
# in the VM
cd ~/ospfv2
docker compose --profile frr up -d sim frr
full=; for i in $(seq 45); do docker compose exec -T frr vtysh -c 'show ip ospf neighbor' </dev/null 2>/dev/null | grep -q '1\.1\.1\.1.*Full' && full=1 && break; sleep 2; done; [ "$full" ] && echo sim Full || docker compose logs --tail 40 frr
docker compose up -d ospfd
cd ~/routescope && docker compose up -d
curl -s --max-time 5 localhost:8082/api/health; echo
```

The wait gives up after about 90 seconds and shows FRR's last log lines. Then open http://localhost:8082 on the Mac.

## Restart

Everything, lab and routescope:

```sh
# in the VM
cd ~/ospfv2
docker compose --profile frr --profile ospfd down
docker compose --profile frr up -d sim frr
full=; for i in $(seq 45); do docker compose exec -T frr vtysh -c 'show ip ospf neighbor' </dev/null 2>/dev/null | grep -q '1\.1\.1\.1.*Full' && full=1 && break; sleep 2; done; [ "$full" ] && echo sim Full || docker compose logs --tail 40 frr
docker compose up -d ospfd
cd ~/routescope && docker compose restart
```

One node at a time:

```sh
# in the VM, from ~/ospfv2
docker compose restart ospfd
docker compose restart frr
docker compose restart sim                     # also fixes a simulator stuck in ExStart
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
cd ~/ospfv2 && docker compose --profile frr --profile ospfd down
```

`down` keeps the lab folder. Your saved configurations stay.

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
