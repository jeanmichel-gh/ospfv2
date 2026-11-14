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
                                            r2-r3: 10.1.23.0/30
```

Links: i1-i2 10.0.12.0/30, i1-asbr 10.0.14.0/30, i2-asbr 10.0.24.0/30, i3-asbr 10.0.34.0/30. Each IS-IS router also puts 172.16.N.0/24 (a static blackhole route) into IS-IS. r1 gives AS 65000's routes to r2 and r3 with itself as next hop.

Things to watch:
- i1 and i2 see none of area 49.0002's prefixes, only asbr's own link to it (10.0.34.0/30). They reach i3, and AS 65001, by a default route that follows asbr's attached bit.
- i3 sees none of area 49.0001's prefixes, only asbr's own links there (10.0.14.0/30, 10.0.24.0/30): FRR 10.2.1 does not carry level 1 prefixes into level 2. asbr's level 2 LSP holds its own prefixes and a default route, which i3 uses for the rest.
- The IS-IS metric becomes the BGP MED: i3's loopback reaches AS 65001 with MED 20, and 172.16.3.0/24 with MED 10. Set `isis metric 50` on asbr's eth3 and they become 60 and 50.
- The route map ISIS-TO-BGP in `asbr/frr.conf` gives area 49.0002's prefixes (10.255.0.3/32 and 172.16.3.0/24) community 65000:2. Make entry 10 deny and both leave AS 65001.

The BGP labs reuse the names r1, r2 and r3. Each lab's containers are named `clab-LAB-NODE`, so the labs can run side by side.

Images: FRR (`docker pull quay.io/frrouting/frr:10.2.1`), and `ospfv2-bird:latest`, built in the ospfv2 checkout (`docker compose --profile bird build bird`).

Start it from routescope's Labs panel, or in this folder: `sudo containerlab deploy -t isis-bgp.clab.yml`.
