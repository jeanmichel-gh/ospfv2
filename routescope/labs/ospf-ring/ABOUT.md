# The router lab on containerlab: a ring

The simulator floods a 5x5 grid to FRR on a LAN. FRR, ospfd and BIRD are joined by a ring of point-to-point links, so a link can fail and traffic take the other way round.

```
       sim 1.1.1.1 (simulated 5x5 grid behind it)
         | eth1  10.99.0.0/24  (broadcast, FRR is the DR)
       frr 2.2.2.2
  eth2 /           \ eth3
 10.0.23.0/30     10.0.24.0/30
  eth1 /           \ eth2
 ospfd 3.3.3.3 --- bird 4.4.4.4
     eth2  10.0.34.0/30  eth1
```

Try: take `frr`'s eth2 down, and ospfd reaches 2.2.2.2 through BIRD. The scenario `ring-failover` does it and measures it: measured on 2026-11-14, ospfd took the route through BIRD, at cost 20, 65 ms after the link went down, and had it back directly, at cost 10, 11 s after the link came up, the adjacency having to form again first.

## What it holds

Measured on 2026-11-14 with all four routers up:

- **The simulated area** is ospf-lab's: grid routers `0.R.0.C`, each grid link a /30 in 13.0.0.0/8, `edge` 10.0.0.1 with loopback 10.255.0.1, 42 links.
- **LSAs: 281 on every router.** 31 router and network LSAs (25 grid, edge, sim, FRR, ospfd, BIRD, and FRR's network LSA as DR on the LAN), 50 summaries and 200 externals.
- **Routes: 300 on ospfd and BIRD.** ospf-lab's 294, plus the three ring /30s and the loopbacks 2.2.2.2, 3.3.3.3 and 4.4.4.4. ospfd installs 297: its two ring subnets and its own loopback are connected.
- **Adjacencies:** the simulator Full with FRR, the DR, on the LAN; the three ring links Full, point to point.
- **Timers:** hello 2 s and dead 8 s on every link.

Images: `ospfv2:latest` and `ospfv2-bird:latest`, built in the ospfv2 checkout (`docker build -t ospfv2 . && docker compose --profile bird build bird`), and FRR (`docker pull quay.io/frrouting/frr:10.2.1`).

Start it from routescope's Labs panel, or in this folder: `sudo containerlab deploy -t ospf-ring.clab.yml`.
