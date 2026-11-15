# Nokia SR Linux in the router lab

The simulator floods a 5x5 grid to SR Linux on a LAN, and ospfd sits behind SR Linux on a point-to-point link.

```
       sim 1.1.1.1 (simulated 5x5 grid behind it)
         | eth1  10.99.0.0/24  (broadcast, SR Linux is the DR)
       srl 2.2.2.2  ethernet-1/1 (e1-1)
         | ethernet-1/2 (e1-2)  10.0.23.0/30  point-to-point
       ospfd 3.3.3.3  eth1
```

SR Linux's configuration is `srl/config.cli`: `set` lines applied when it boots. Its ports are `ethernet-1/1` and `ethernet-1/2` in its CLI, `e1-1` and `e1-2` for Linux and routescope's link faults. It needs about 2 GB of memory while running, and boots in about a minute.

## What it holds

Measured on 2026-11-14:

- **The simulated area** is ospf-lab's: grid routers `0.R.0.C`, each grid link a /30 in 13.0.0.0/8, `edge` 10.0.0.1 with loopback 10.255.0.1, 42 links.
- **LSAs: 280 on the simulator and ospfd.** 30 router and network LSAs (25 grid, edge, sim, SR Linux, ospfd, and SR Linux's network LSA as DR), 50 summaries and 200 externals.
- **Routes: 297 on ospfd.** 42 link subnets, edge's loopback, the 250 summary and external routes, the LAN, the point-to-point /30, and the loopbacks 2.2.2.2 and 3.3.3.3. It installs 295: its /30 and its own loopback are connected.
- **Adjacencies:** the simulator Full with SR Linux, the DR (priority 10), on the LAN; ospfd Full with SR Linux, point to point.
- **Boot:** routescope saw every router up 12 s after containerlab finished.

The scenario `edge-down` takes the simulator's link to `edge` down and up. Measured on 2026-11-14: ospfd lost edge's routes 61 ms after the link went down and had them back 5.3 s after it came up. The 5 s is ospfd's SPF back-off (RFC 8405), not SR Linux: see ospf-lab's ABOUT.md, "Convergence".

## Images

Images: `ospfv2:latest`, built in the ospfv2 checkout (`docker build -t ospfv2 .`), and SR Linux, free from Nokia (`docker pull ghcr.io/nokia/srlinux:26.3.1`).

Start it from routescope's Labs panel, or in this folder: `sudo containerlab deploy -t ospf-srl.clab.yml`.
