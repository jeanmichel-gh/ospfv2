# Lab console plan

A web console for the ospfd router lab: one window to see, drive, debug and record every device in the lab. It goes well past the demo dashboard, which shows one simulator and polls it.

Status: plan agreed in outline, phase 0 (UX mockups) in progress.

## Goals

- See the whole lab at once: devices, links, adjacencies, routes, all live.
- Work on any device the same way: terminal, OSPF state, configuration, logs, captures.
- Debug OSPF at the bit level and in time: packets decoded field by field, timers drawn on a timeline.
- Record what happened and replay it. Script scenarios with assertions, so the lab becomes a test bench.
- Stay generic: devices are reached through drivers, so other routers and other lab layouts fit later.

## Decisions

| # | Decision | Status |
| --- | --- | --- |
| 1 | Front end in React and TypeScript, built with Vite | Agreed |
| 2 | Backend in Ruby (Async, Falcon, websockets), loads `lib/ospfv2` for decoding | Agreed |
| 3 | The console runs as a container in the VM, the browser on the Mac through a QEMU port forward | Agreed |
| 4 | Works with ospfd running natively in the VM or in its container | Agreed |
| 5 | Our own small lab file first. Containerlab import later; nothing in the design may block it | Agreed |
| 6 | Single user on localhost, but auth built in from day one and switched off, so login is easy to add | Agreed |
| 7 | Separate repo for the console, its own license; ospfv2 gets the APIs it needs as normal features | Proposed, to confirm |

ospfv2 stays standard library only. The console has its own gems and Node packages.

## What the console does

1. **Lab map.** Containers, segments, addresses, adjacencies colored by state. The simulated area shows as a cloud behind `sim` that expands into its routers. Click anything to inspect it.
2. **Device inspector.** Overview, neighbors, interfaces, LSDB, OSPF routes, kernel routes, configuration. The same tables for ospfd, FRR and the simulator.
3. **Terminals.** xterm.js tabs and splits: a shell in any node, `vtysh` on FRR, `ospf-cli` on ospfd.
4. **LSDB explorer.** The databases of all routers side by side, differences highlighted: missing LSAs, older sequence numbers, checksum mismatches.
5. **Packet decoder.** Wireshark style: packet list, field tree, hex dump. Selecting a field highlights its bytes; flag fields show each bit (Options, router LSA V/E/B, DD I/M/MS). Packet and LSA Fletcher checksums are verified. An LSA instance can be followed through flood, ack and retransmit. Optional cross check with `tshark`. Save as pcap.
6. **Timers.** One lane per timer, per device, interface and neighbor, scrolling with time: hello, dead, wait, retransmit, inactivity, LSA refresh, MinLSInterval, MinLSArrival, MaxAge, SPF delay and hold, delayed ack. Exact for ospfd, measured from captures for FRR and the simulator. Checks flag hello or dead mismatch, near expiries, retransmit pile ups and SPF throttling.
7. **Timeline.** One correlated event stream across devices: state changes, floods, SPF runs, link flaps, commits. Scrub back in time.
8. **Recording.** Start, act, stop. The bundle holds logs, pcap, events and before and after snapshots, and replays in the timeline.
9. **Config workbench.** ospfd candidate, compare, commit, history, rollback. FRR running configuration. Simulator YAML with `check` validation and apply.
10. **Scenarios.** Short scripts with assertions: flap link 3 five times, wait for Full, expect 293 routes, measure convergence. Results kept as reports.
11. **Lab lifecycle.** Up, down, restart a node, health, start order handled (the simulator Full before ospfd).

## Architecture

```
Mac browser ── QEMU forward 127.0.0.1:8082 ──► console container (VM)
                                                 │ Falcon: static UI + websocket API
                                                 │ auth gate ─► lab service ─► drivers
                                                 ├─ Docker socket: exec, logs, lifecycle
                                                 ├─ /run/ospfv2: ospfd JSON socket
                                                 └─ nsenter: captures, host shell
```

- **Lab file.** Lists nodes with a kind and a location, and the segments between them. Compose is the default way to bring the lab up.
- **Drivers.** Each kind declares capabilities: terminal, show, config, logs, capture, lifecycle. Shows return a normalized model (neighbors, interfaces, LSAs, routes), so the panes do not care which router answered.
  - `ospfd`: the JSON socket API. Location `host` or `container: <name>`.
  - `frr`: `vtysh -c "... json"` through `docker exec`.
  - `ospfv2-sim`: its HTTP API.
  - `linux`: terminal and capture only, for anything else.
- **Native ospfd.** The console mounts `/run/ospfv2` from the VM and runs with host PID access to enter the VM's namespaces for the shell and captures. A systemd unit for ospfd gives start, stop and logs through the journal.
- **Streams.** Websockets carry terminals, events, timers and live captures. All nodes share the VM kernel clock, so timestamps line up.
- **Auth.** Every request passes one gate and carries a user. Today the gate returns the local admin. Roles viewer, operator and admin exist from the start. Every API path holds a lab id. Adding login is adding a provider, then password or GitHub and Google sign in.
- **Audit.** Every action is logged with its user: useful today, needed once there are logins.

## Changes needed in ospfv2

| Change | Why |
| --- | --- |
| Event subscription on the ospfd API (`events.subscribe`, streamed JSON lines) | Live timeline without polling |
| Timer table on the ospfd API: every armed timer with its owner and next fire time | Exact timers view |
| Field offsets in the packet and LSA decoder: name, value, byte offset, length, bit mask | Bit level decoder |
| Streaming endpoint on the simulator web API | Live simulator events |
| Socket on a volume in the containerized ospfd, documented | Console reaches it |
| systemd unit for native ospfd | Lifecycle and journal logs |

## Phases

0. **UX.** Clickable mockups of the main screens: map, inspector, decoder, timers, then terminals, LSDB diff, timeline. Iterate until agreed.
1. **Skeleton.** Repo, backend with Docker driver and lab file, front end shell with docking layout, node list, health, terminals. Auth gate in place.
2. **Live OSPF views.** ospfd, FRR and simulator drivers, normalized tables, live map. ospfd event subscription.
3. **Config workbench.** ospfd, FRR, simulator YAML.
4. **Observability.** Timeline, log streaming and search, capture and decoder with field offsets, recording.
5. **Timers and analysis.** Timer API and timers view, LSDB and route diffs, SPF tree, convergence timing.
6. **Scenarios.** Script format, runner, assertions, reports.
7. **Generality.** Containerlab import, generic driver, cEOS.

Each phase ends usable on its own.

## Main libraries

| Need | Choice |
| --- | --- |
| Docking panes | dockview |
| Terminals | xterm.js |
| Map | React Flow, Cytoscape for large graphs |
| Editors | Monaco |
| Tables | TanStack Table with virtualization |
| Server | Falcon, async-websocket |

## Open questions

- Repo name and license for the console.
- Scenario script format: Ruby DSL or YAML.
- How long recordings are kept, and where.
