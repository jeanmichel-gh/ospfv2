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

The BGP labs reuse the names r1, r2 and r3, so run one at a time.

Images: FRR (`docker pull quay.io/frrouting/frr:10.2.1`), and `ospfv2-bird:latest`, built in the ospfv2 checkout (`docker compose --profile bird build bird`).

Start it from routescope's Labs panel, or in this folder: `sudo containerlab deploy -t bgp-ibgp.clab.yml`.
