---
title: ospfd forwarding on SR-MPLS labels
tags: [ospf, sr, mpls]
role: main
---
# ospfd forwarding on SR-MPLS labels

Four ospfd routers in a line, OSPF area 0 with segment routing over MPLS (RFC 8665). Each loopback has a Node-SID, and ospfd installs its labels in its container's kernel. The main lab for SR in OSPF: it runs only ospfd, the owner's Ruby code. `ospf-sr-frr` is the interop check with FRR.

```
  o1 ---- o2 ---- o3 ---- o4      area 0, point-to-point
  16000   17000   18000   19000   SRGB start
  idx 1   idx 2   idx 3   idx 4   Node-SID on 10.255.0.N/32
      10.0.12.0/30    10.0.23.0/30    10.0.34.0/30
```

The SRGBs differ on purpose: a label is always taken from the next router's block, so one from the wrong block would show.

## What to look for

Measured on ospflab, 2026-11-28, ospfd at ospfv2 `a065d34` (`test/lab/sr_test.sh`, 38 checks with `ospf-sr-frr`):

- `ip -M route` on o1: 16004 swaps to 17004 toward o2, for o4's loopback; on o2, 17004 swaps to 18004 toward o3; on o3, 18004 pops before o4 (PHP). Each router's Adj-SIDs, 15000 and up, pop onto their links.
- `ip route show proto 89` on o1: `10.255.0.4 encap mpls 17004 via 10.0.12.2`, ospfd pushing the label for o4's loopback.
- `ospf-cli -c 'show mpls label'` lists the same table, and `show ospf segment-routing` every router's SRGB and Node-SID. Each router's label table is its kernel's.
- A ping from o1's loopback to o4's crosses on labels: tcpdump shows 17004 from o1 to o2, 18004 from o2 to o3, and plain IP from o3 to o4. The ospfv2 image has no `ping`: run the host's in o1's network namespace, `sudo nsenter -t $(docker inspect -f '{{.State.Pid}}' clab-ospf-sr-o1) -n ping -I 10.255.0.1 10.255.0.4`.
