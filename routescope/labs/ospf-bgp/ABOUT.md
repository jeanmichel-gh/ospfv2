# OSPF into BGP

Two AS domains. AS 65000 runs OSPF: the simulator (a 3x3 grid, about 30 LSAs), ospfd, and asbr (FRR), which redistributes OSPF into BGP. AS 65001 is three iBGP speakers, full mesh: r1 and r2 (FRR), r3 (BIRD). asbr and r1 peer by eBGP; r1 gives AS 65000's routes to r2 and r3 with itself as next hop.

```
  AS 65000 (OSPF area 0)                     AS 65001 (iBGP)

  sim 1.1.1.1 --LAN 10.99.0.0/24-- asbr 2.2.2.2 --eBGP 10.1.100.0/30-- r1 10.255.1.1
  (3x3 grid behind)                 |                                  /  \
                      10.0.23.0/30  |                       10.1.12.0/30  10.1.13.0/30
                                ospfd 3.3.3.3                         r2 ---- r3
                                                                 10.255.1.2  10.255.1.3 (BIRD)
```

The BGP labs reuse the names r1, r2 and r3, so run one at a time.

Images: `ospfv2:latest` and `ospfv2-bird:latest`, built in the ospfv2 checkout (`docker build -t ospfv2 . && docker compose --profile bird build bird`), and FRR (`docker pull quay.io/frrouting/frr:10.2.1`).

Start it from routescope's Labs panel, or in this folder: `sudo containerlab deploy -t ospf-bgp.clab.yml`.
