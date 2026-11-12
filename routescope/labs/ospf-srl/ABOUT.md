# Nokia SR Linux in the router lab

The simulator floods a 5x5 grid to SR Linux on a LAN, and ospfd sits behind SR Linux on a point-to-point link.

```
       sim 1.1.1.1 (simulated 5x5 grid behind it)
         | eth1  10.99.0.0/24  (broadcast, SR Linux is the DR)
       srl 2.2.2.2  ethernet-1/1 (e1-1)
         | ethernet-1/2 (e1-2)  10.0.23.0/30  point-to-point
       ospfd 3.3.3.3  eth1
```

SR Linux's configuration is `srl/config.cli`: `set` lines applied when it boots. Its ports are `ethernet-1/1` and `ethernet-1/2` in its CLI, `e1-1` and `e1-2` for Linux and routescope's link faults. It needs about 2 GB of memory while running, and boots in about a minute.

Images: `ospfv2:latest`, built in the ospfv2 checkout (`docker build -t ospfv2 .`), and SR Linux, free from Nokia (`docker pull ghcr.io/nokia/srlinux:26.3.1`).

Start it from routescope's Labs panel, or in this folder: `sudo containerlab deploy -t ospf-srl.clab.yml`.
