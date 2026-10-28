# routescope: lab console plan

routescope is a web console for the ospfd router lab: one window to see, drive, debug and record every device in the lab. It goes well past the demo dashboard, which shows one simulator and polls it.

Status: plan agreed in outline, phase 0 (UX mockups) in progress. Each pane, its inputs and decisions: `console-panes.md`.

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
| 7 | Separate private repo `jeanmichel-gh/routescope`, its own license, cloned side by side with ospfv2; ospfv2 gets the APIs it needs as normal features | Agreed |
| 8 | A lab is a folder: `lab.yml` plus one config file per node, mounted read-write, kept in git | Agreed |
| 9 | SPF observability lives in ospfd; ospf-cli and the console both read it | Agreed |

ospfv2 stays standard library only. The console has its own gems and Node packages.

## Working across the two repos

- **The APIs are the contract:** ospfd's JSON socket API, the simulator's HTTP API, and the ospfv2 library the console loads for decoding.
- **Additive changes only.** New methods and fields are fine; renames and removals go through a deprecation. ospfv2 can always merge first without breaking the console.
- **Discovery.** ospfd answers `api.info` with its version and methods. The console checks it at connect and greys out what an older ospfd lacks, with a message naming the version needed.
- **Shared fixtures.** ospfv2's tests record sample responses of each API method in `test/fixtures/api/`. The console's tests use the same files.
- **Side by side clones** on the Mac and in the VM: `~/src/ospfv2` and `~/src/routescope`.
- **Pinned, with a local override.** The console pins ospfv2 to a tag in its Gemfile and compose file. For local work, `bundle config local.ospfv2 ~/src/ospfv2` and a compose build context of `../ospfv2` use the sibling checkout directly.
- **A feature that spans both** is two linked PRs: ospfv2 first, merged and tagged, then the console bumps its pin.

## What the console does

1. **Lab map.** Containers, segments, addresses, adjacencies colored by state. The simulated area shows as a cloud behind `sim`. Click anything to inspect it. Inspecting the simulated area gives the demo's controls in place: its grid with links to click down or up, flap, metric, refresh, aging and flush, plus a link to the full simulator workbench.
2. **Device inspector.** Overview, neighbors, interfaces, LSDB, OSPF routes, kernel routes, configuration. The same tables for ospfd, FRR and the simulator.
3. **Terminals.** xterm.js tabs and splits: a shell in any node, `vtysh` on FRR, `ospf-cli` on ospfd.
4. **Simulator workbench.** The simulated topology drawn as routers and links, like the demo dashboard. Click a link to take it down or up, a router to inspect it. Refresh one LSA or all, flush, flap, aging on or off, add or withdraw externals. A log shows what each action originated and when frr and ospfd installed it.
5. **LSDB explorer.** The databases of all routers side by side, differences highlighted: missing LSAs, older sequence numbers, checksum mismatches.
6. **Packet decoder.** Wireshark style: packet list, field tree, hex dump. Selecting a field highlights its bytes; flag fields show each bit (Options, router LSA V/E/B, DD I/M/MS). Packet and LSA Fletcher checksums are verified. An LSA instance can be followed through flood, ack and retransmit. Optional cross check with `tshark`. Save as pcap.
7. **Timers.** One lane per timer, per device, interface and neighbor, scrolling with time: hello, dead, wait, retransmit, inactivity, LSA refresh, MinLSInterval, MinLSArrival, MaxAge, SPF delay and hold, delayed ack. Exact for ospfd, measured from captures for FRR and the simulator. Checks flag hello or dead mismatch, near expiries, retransmit pile ups and SPF throttling.
8. **SPF runs.** Live, one column per router on a shared time axis. Each run shows its triggers (LSA instances, clickable to the LSDB and the decoder), a timing bar (wait, compute, FIB install) and its route diff. A chart strip shows runs and duration over time. One LSA instance can be followed from origination to the kernel route on every router, which measures convergence end to end. Rows freeze while selected; "follow live" resumes.
9. **Timeline.** One correlated event stream across devices: state changes, floods, SPF runs, link flaps, commits. Scrub back in time.
10. **Recording.** Start, act, stop. The bundle holds logs, pcap, events and before and after snapshots, and replays in the timeline. A recording names the lab version it ran on.
11. **Config workbench.** Per node: startup (the lab file), running, and for ospfd the candidate. A badge shows when running differs from startup; a diff lets you save or revert line by line. ospfd keeps compare, commit check, commit and rollback. FRR changes apply through vtysh. Simulator YAML with `check` validation and apply. Changes made in a terminal show up too (see Lab folder). Authentication keys masked.
12. **Scenarios.** Short scripts with assertions: flap link 3 five times, wait for Full, expect 293 routes, measure convergence. Results kept as reports.
13. **Lab lifecycle.** Up, down, restart a node, health, start order handled (the simulator Full before ospfd).

## Architecture

```
Mac browser ── QEMU forward 127.0.0.1:8082 ──► routescope container (VM)
                                                 │ Falcon: static UI + websocket API
                                                 │ auth gate ─► lab service ─► drivers
                                                 ├─ Docker socket: exec, logs, lifecycle
                                                 ├─ /run/ospfv2: ospfd JSON socket
                                                 └─ nsenter: captures, host shell
```

- **Lab folder.** One directory per lab: `lab.yml` lists nodes with a kind and a location, and the segments between them; next to it, one startup config per node (`ospfd.conf`, `frr.conf`, `sim.yml`). Compose mounts each file read-write into its node. The repo's `examples/lab` becomes a template to copy. The console reads and writes only inside the lab folder.
- **Save flow.** "Save to lab" writes a node's running config to its file: ospfd already does on commit, FRR through `write memory` or the console writing the file, the simulator by exporting its topology (runtime state such as a link taken down in the UI is saved only if asked). The lab folder is a git repo: each save is a commit with a message, so the lab has history, diffs, a branch per experiment and one click rollback.
- **Change detection.** ospfd announces commits on its event stream. FRR has no commit event: the console re-reads `show running-config` after each command typed in its FRR terminal, plus a slow poll for changes made elsewhere. A file changed on disk outside the console shows as a conflict to merge, never overwritten.
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
| SPF triggers carry the LSA instance, its source and arrival time; runs carry a number, start, end, FIB done and the route diff (capped); LSAs and routes link back to the run they triggered or that changed them | SPF runs pane, convergence chain |
| ospf-cli: `show ospf log` timing columns, `show ospf log run N`, SPF links in route and database detail; IOS forms too | Same insight without the console |
| Compose and lab template: per node configs mounted read-write from a lab folder, not baked in the image or read only | Save to lab |
| Socket on a volume in the containerized ospfd, documented | Console reaches it |
| `api.info`: version and supported methods; recorded API fixtures in `test/fixtures/api/` | Cross repo contract |
| systemd unit for native ospfd | Lifecycle and journal logs |

## Phases

0. **UX.** Clickable mockups of the main screens: map, inspector, simulator, decoder, timers, LSDB diff, then SPF runs, config workbench, terminals, timeline. Iterate until agreed.
1. **Skeleton.** Repo, backend with Docker driver and lab folder (the compose change comes first), front end shell with docking layout, node list, health, terminals. Auth gate in place.
2. **Live OSPF views.** ospfd, FRR and simulator drivers, normalized tables, live map. ospfd event subscription.
3. **Config workbench.** ospfd, FRR, simulator YAML. Startup vs running diff, save to lab, git history.
4. **Observability.** Timeline, log streaming and search, capture and decoder with field offsets, recording.
5. **Timers and analysis.** Timer API and timers view, SPF observability in ospfd and the SPF runs pane, LSDB and route diffs, SPF tree, convergence timing.
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

- License for routescope. None while the repo is private.
- Scenario script format: Ruby DSL or YAML.
- How long recordings are kept, and where.
