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
