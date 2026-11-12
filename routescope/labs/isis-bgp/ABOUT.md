# IS-IS into BGP

Two AS domains. AS 65000 runs IS-IS on FRR: i1 and i2 at level 1 in area 49.0001, i3 at level 2 in area 49.0002, and asbr, level 1 and 2, which joins the two areas and redistributes IS-IS into BGP. AS 65001 is three iBGP speakers, full mesh: r1 and r2 (FRR), r3 (BIRD). asbr and r1 peer by eBGP.

```
  AS 65000 (IS-IS)                           AS 65001 (iBGP)

  i1 10.255.0.1 ---- i2 10.255.0.2
        \              /       level 1
         \            /
        asbr 10.255.0.4 ---eBGP 10.1.100.0/30--- r1 10.255.1.1
             |         level 1 and 2             /  \
             |                       10.1.12.0/30    10.1.13.0/30
        i3 10.255.0.3  level 2                 r2 ---------- r3 (BIRD)
                                         10.255.1.2      10.255.1.3
```

Things to watch:
- i1 and i2 see nothing of area 49.0002. They get there by a default route that follows asbr's attached bit.
- i3 sees nothing of area 49.0001: FRR does not carry level 1 prefixes into level 2. asbr gives it a default route at level 2.
- The IS-IS metric becomes the BGP MED. `isis metric 50` on asbr's eth3, and i3's prefixes reach AS 65001 with MED 60.
- The route map ISIS-TO-BGP in `asbr/frr.conf` gives area 49.0002's prefixes community 65000:2. Make it deny and they leave AS 65001.

The BGP labs reuse the names r1, r2 and r3, so run one at a time.

Images: FRR (`docker pull quay.io/frrouting/frr:10.2.1`), and `ospfv2-bird:latest`, built in the ospfv2 checkout (`docker compose --profile bird build bird`).

Start it from routescope's Labs panel, or in this folder: `sudo containerlab deploy -t isis-bgp.clab.yml`.
