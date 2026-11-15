# The router lab: OSPF on one LAN

The ospfv2 simulator floods a 5x5 grid of routers to FRR on the LAN 10.99.0.0/24. Behind the grid, `edge` has 50 summary and 200 external routes. ospfd and BIRD 2 join the same LAN as more routers under test.

| Node | Router ID | Address | What |
| --- | --- | --- | --- |
| sim | 1.1.1.1 | 10.99.0.10 | the simulator; its dashboard on :8080 |
| frr | 2.2.2.2 | 10.99.0.20 | FRR, the DR |
| ospfd | 3.3.3.3 | 10.99.0.30 | ospfv2's router |
| bird | 4.4.4.4 | 10.99.0.40 | BIRD 2, priority 0 |

It is a compose lab: `lab.yml` lists the nodes, and `docker-compose.yml` in the ospfv2 checkout runs them with `LAB` set to this folder. Each node's folder is mounted read-write, so a saved configuration lands back here.

## What it holds

Measured on 2026-11-14 with all four routers up:

- **Addresses in the simulated area.** A grid router at row R, column C
  has router ID `0.R.0.C` (r1c1 is 0.1.0.1). Each grid link is its own
  /30 in 13.0.0.0/8. `edge` is 10.0.0.1, with loopback 10.255.0.1.
- **Links: 42.** 40 inside the grid, plus sim to r1c1 and r5c5 to edge,
  as `sim/sim.yml` says.
- **LSAs: 281 on every router.** 31 router and network LSAs (25 grid,
  edge, sim, FRR, ospfd, BIRD, and FRR's network LSA as DR), 50
  summaries and 200 externals.
- **Routes: 294 on ospfd and BIRD.** 42 link subnets, edge's loopback,
  the 250 summary and external routes, and the LAN. ospfd installs 293:
  the LAN, 10.99.0.0/24, is connected, so it puts no route in the kernel
  for it.
- **Timers:** hello 2 s and dead 8 s on all four. ospfd's dead interval is
  four times its hello unless set.

## Convergence

The scenario `edge-down` measured on 2026-11-14: ospfd lost edge's routes 81 ms after the link went down, and had them back 5.1 s after it came up.

ospfd runs SPF with RFC 8405's back-off, at its default values (section 6): the first change after a quiet spell waits 50 ms, and a change within 10 s of the last one, once 500 ms have passed, waits 5 s. A link back up 1.3 s after it went down is such a change, so its routes come back about 5 s later. Measured on ospf-lab on 2026-11-14 with r5c5--edge: up 1.3 s after down, ospfd's SPF waited 5000.7 ms; up 15 s after down, it waited 50.1 ms. `show ospf log` shows each run's wait.

## Roles

The simulator and ospfd run at priority 0, so FRR is the DR and there is no BDR. That is a choice, not a need: give ospfd a priority above 0 and it becomes the BDR, and the simulator keeps an adjacency with both (`docs/design/sim-dr-bdr.md`).

Scenarios: `edge-down` takes the link to `edge` down and up and measures how long ospfd takes; `flap-converge` flaps a link next to the simulator three times.

So the simulator reaches the lab through FRR: its one Full adjacency is with the DR. ospfd and BIRD are Full with FRR and at 2-Way with each other and the simulator.

## FRR's start script

`tools/frr-start.sh` starts FRR and, every 2 seconds, gives `frr.conf` back to the lab folder's owner, since `write memory` hands it to FRR's user. compose mounts it from the ospfv2 checkout, not from your copy of the lab, so that lab folders made before the script existed still start FRR (ospfv2 e2dbeb7). Editing it in `~/labs` changes nothing. The lab's `.gitignore` lists it too, so it is not in the lab's git.

## Running it

Images, built in the ospfv2 checkout: `docker build -t ospfv2 .`, and `docker compose --profile bird build bird` for BIRD. FRR is pulled.

Start it from routescope's Labs panel, or from the ospfv2 checkout:

```sh
export LAB=~/labs/ospfv2/ospf-lab
docker compose --profile frr up -d sim frr
docker compose up -d ospfd
docker compose --profile bird up -d bird
```
