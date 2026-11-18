---
title: Three iBGP speakers on FRR and BIRD
tags: [bgp]
role: reference
---
# Three iBGP speakers

Three BGP speakers in AS 65001 peer with one another (iBGP, full mesh) over a triangle of links. r1 and r2 run FRR, r3 runs BIRD. Each advertises its loopback (10.255.1.N) and a /24 (192.168.N.0/24).

```
             r1 10.255.1.1  192.168.1.0/24
    eth1 /                  \ eth2
  10.1.12.0/30          10.1.13.0/30
    eth1 /                  \ eth2
  r2 10.255.1.2 --------- r3 10.255.1.3
  192.168.2.0/24  eth2  10.1.23.0/30  eth1  192.168.3.0/24
```

## What to see

- Every router holds six routes, in BGP and in its kernel: the three loopbacks and the three /24s. Loopback to loopback pings work.
- Each /24 is a blackhole route on the router that advertises it. A ping into one fails by design.
- The sessions run on the link addresses, and there is no IGP. When a link fails, its session ends when the hold time (9 s) runs out, and the two routers lose each other's routes. The third router still holds them but does not pass them on: a route learned from one iBGP peer is not sent to another.
- The scenario `link-down` shows it on the r1-r2 link. Measured on the VM, twice: r1 lost r2's routes after 8.7 s and 7.6 s, and had them back 1.2 s after the link came up.

The BGP labs reuse the names r1, r2 and r3. Each lab's containers are named `clab-LAB-NODE`, so the labs can run side by side.

Images: FRR (`docker pull quay.io/frrouting/frr:10.2.1`), and `ospfv2-bird:latest`, built in the ospfv2 checkout (`docker compose --profile bird build bird`).

Start it from routescope's Labs panel, or in this folder: `sudo containerlab deploy -t bgp-ibgp.clab.yml`.
