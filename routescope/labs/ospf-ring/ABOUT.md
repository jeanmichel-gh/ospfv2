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

Try: take `frr`'s eth2 down, and ospfd reaches 2.2.2.2 through BIRD.

Images: `ospfv2:latest` and `ospfv2-bird:latest`, built in the ospfv2 checkout (`docker build -t ospfv2 . && docker compose --profile bird build bird`), and FRR (`docker pull quay.io/frrouting/frr:10.2.1`).

Start it from routescope's Labs panel, or in this folder: `sudo containerlab deploy -t ospf-ring.clab.yml`.
