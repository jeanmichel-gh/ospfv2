---
title: "BFD for OSPF: ospfd and FRR, the interop check"
tags: [ospf, bfd]
role: interop
---
# BFD for OSPF: ospfd and FRR

The interop check for BFD in ospfd: ospfd and FRR on one point-to-point link, each running BFD (RFC 5880, 5881) for its OSPF neighbor (RFC 5882). ospfd asks `bfdd4r` for the session through bfd4r's client; FRR asks its own `bfdd`. `test/lab/bfd_test.sh` runs it and is its gate.

```
  ospfd 1.1.1.1  eth1 --- 10.0.12.0/30 --- eth1  frr 2.2.2.2
```

## What it shows

- **BFD Up on both, the neighbor Full.** `show ospf neighbor | display json` on ospfd has `"bfd": "up"`; `show bfd peers` on FRR says `Status: up`.
- **The link fails: the neighbor Down in under a second on both.** Both sides ask for 300 ms and a multiplier of 3, FRR's defaults, so BFD gives up within 900 ms of the last packet. 300 ms is also the least bfdd4r accepts: its floor (bfd4r `docs/daemon.md`); under it, ospfd logs bfdd4r's refusal and runs the neighbor without BFD. OSPF alone, with hello 2 s and dead 8 s, would wait 8 s. On ospfd the `neighbor` event's `event` is `BFD down`.
- **The link back: the neighbor Full again.** ospfd lets the session go when the neighbor goes Down, and asks for it again at 2-Way.

A neighbor never waits for BFD: OSPFv2 has no way to say it runs BFD (RFC 5882 4.1). A session going AdminDown takes no neighbor down (RFC 5882 4.2). If `bfdd4r` is not running, ospfd keeps its neighbors and logs a warning once.

## Try

```sh
docker exec clab-ospf-bfd-ospfd ospf-cli -c 'show ospf neighbor | display json'
docker exec clab-ospf-bfd-ospfd bfd4r-cli --pretty show.sessions
docker exec clab-ospf-bfd-frr vtysh -c 'show bfd peers'
sudo containerlab tools netem set -n clab-ospf-bfd-ospfd -i eth1 --loss 100   # the link fails
sudo containerlab tools netem set -n clab-ospf-bfd-ospfd -i eth1 --loss 0      # and comes back
docker exec clab-ospf-bfd-ospfd ospf-cli -c 'show ospf events'
```

Images: `ospfv2:latest`, built in the ospfv2 checkout with bfd4r cloned beside it (`docker build -t ospfv2 --build-context bfd4r=../bfd4r .`), and FRR (`docker pull quay.io/frrouting/frr:10.2.1`).

Start it from routescope's Labs panel, or in this folder: `sudo containerlab deploy -t ospf-bfd.clab.yml`.
