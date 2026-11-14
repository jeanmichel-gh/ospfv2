# The router lab: OSPF on one LAN

The ospfv2 simulator floods a 5x5 grid of routers to FRR on the LAN 10.99.0.0/24. Behind the grid, `edge` has 50 summary and 200 external routes. ospfd and BIRD 2 join the same LAN as more routers under test.

| Node | Router ID | Address | What |
| --- | --- | --- | --- |
| sim | 1.1.1.1 | 10.99.0.10 | the simulator; its dashboard on :8080 |
| frr | 2.2.2.2 | 10.99.0.20 | FRR, the DR |
| ospfd | 3.3.3.3 | 10.99.0.30 | ospfv2's router |
| bird | 4.4.4.4 | 10.99.0.40 | BIRD 2, priority 0 |

It is a compose lab: `lab.yml` lists the nodes, and `docker-compose.yml` in the ospfv2 checkout runs them with `LAB` set to this folder. Each node's folder is mounted read-write, so a saved configuration lands back here.

The simulator and ospfd run at priority 0, so FRR is the DR and there is no BDR. That is a choice, not a need: give ospfd a priority above 0 and it becomes the BDR, and the simulator keeps an adjacency with both (`docs/design/sim-dr-bdr.md`).

Scenarios: `edge-down` takes the link to `edge` down and up and measures how long ospfd takes; `flap-converge` flaps a link next to the simulator three times.

Images, built in the ospfv2 checkout: `docker build -t ospfv2 .`, and `docker compose --profile bird build bird` for BIRD. FRR is pulled.

Start it from routescope's Labs panel, or from the ospfv2 checkout:

```sh
export LAB=~/labs/ospfv2/ospf-lab
docker compose --profile frr up -d sim frr
docker compose up -d ospfd
docker compose --profile bird up -d bird
```
