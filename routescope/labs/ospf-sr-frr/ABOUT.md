---
title: "SR-MPLS in OSPF: ospfd and FRR, the interop check"
tags: [ospf, sr, mpls]
role: interop
---
# SR-MPLS in OSPF: ospfd and FRR

The interop check for SR in ospfd: two ospfd routers between two FRR routers, OSPF area 0 with segment routing over MPLS (RFC 8665), on FRR 10.2.1, the version ospfv2's labs and CI pin. `ospf-sr` is the main lab, ospfd alone. `test/lab/sr_test.sh` runs both and is their gate.

```
  f1 ---- o1 ---- o2 ---- f2      area 0, point-to-point
  FRR     ospfd   ospfd   FRR
  16000   17000   18000   16000   SRGB start
  idx 1   idx 2   idx 3   idx 4   Node-SID on 10.255.0.N/32
      10.0.12.0/30    10.0.23.0/30    10.0.34.0/30
```

## What to look for

Measured on ospflab, 2026-11-28, ospfd at ospfv2 `a065d34` and FRR 10.2.1 (`test/lab/sr_test.sh`):

- On o1, 17004 swaps to 18004 toward o2, and 17001 pops before f1 (PHP). On o2, 18004 pops before f2, and 18001 swaps to 17001 toward o1. Each ospfd's label table is its kernel's.
- FRR f1's `show ip ospf database segment-routing` lists o1 with SRGB 17000 and o2 with 18000.
- A ping from f1's loopback to f2's, `ping -I 10.255.0.1 10.255.0.4` on f1, crosses on labels: tcpdump shows 17004 into o1, 18004 from o1 to o2, and plain IP from o2 to f2. Back from f2, FRR pushes 18001 and o2 swaps it to 17001 toward o1.
- o1's link to o2 down (`ip link set eth2 down` in o1): o1 holds no label through o2. Up again: its table comes back as it was, and the ping crosses again.
