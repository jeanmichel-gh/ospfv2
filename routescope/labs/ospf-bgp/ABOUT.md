---
title: OSPF redistributed into BGP at an FRR ASBR
tags: [ospf, bgp]
role: interop
---
# OSPF into BGP

Two AS domains. AS 65000 runs OSPF: the simulator (a 3x3 grid behind it), ospfd, and asbr (FRR), which redistributes OSPF into BGP. Area 0 holds 34 LSAs: 13 router LSAs (the 9 grid routers, edge, sim, asbr, ospfd), 1 network LSA (the LAN, from asbr, its DR), and 10 summaries and 10 externals from the grid's edge router 10.0.0.1. AS 65001 is three iBGP speakers, full mesh: r1 and r2 (FRR), r3 (BIRD). asbr and r1 peer by eBGP; r1 gives AS 65000's routes to r2 and r3 with itself as next hop.

```
  AS 65000 (OSPF area 0)                     AS 65001 (iBGP)

  sim 1.1.1.1 --LAN 10.99.0.0/24-- asbr 2.2.2.2 --eBGP 10.1.100.0/30-- r1 10.255.1.1
  (3x3 grid behind)                 |                                  /  \
                      10.0.23.0/30  |                       10.1.12.0/30  10.1.13.0/30
                                ospfd 3.3.3.3                         r2 ---- r3
                                                                 10.255.1.2  10.255.1.3 (BIRD)
                                                                 r2-r3: 10.1.23.0/30
```

The BGP labs reuse the names r1, r2 and r3. Each lab's containers are named `clab-LAB-NODE`, so the labs can run side by side.

Images: `ospfv2:latest` and `ospfv2-bird:latest`, built in the ospfv2 checkout (`docker build -t ospfv2 --build-context bfd4r=../bfd4r . && docker compose --profile bird build bird`), and FRR (`docker pull quay.io/frrouting/frr:10.2.1`).

Start it from routescope's Labs panel, or in this folder: `sudo containerlab deploy -t ospf-bgp.clab.yml`.
