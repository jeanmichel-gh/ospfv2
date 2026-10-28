# routescope: lab console panes

What each pane of routescope, the lab console, shows, where its data comes from, what you can do in it, and what we decided. It goes with `console-plan.md`, which holds the architecture and phases.

The mockups are on the "Lab console mockups" canvas. Screen numbers below refer to it.

Status: phase 0. Decisions are agreed unless marked open.

## Common to all panes

**Layout.** A top bar (lab selector, Record, signed in user), a menu on the left, panes on the right. Panes dock and split like an IDE (dockview). Every pane works at phone width by stacking.

**Live updates.**
- Devices push events; the console never polls when a push exists. ospfd gets `events.subscribe`, the simulator a streaming endpoint.
- Updates are batched a few times per second. A burst such as a refresh of 276 LSAs shows as one change, not 276.
- Selecting or hovering a row freezes its list. "Follow live" resumes.
- Changed rows flash briefly.

**Linking.** The LSA instance (type, Link State ID, advertising router, sequence) is the key every pane shares. It links the simulator log, LSDB, packets, SPF runs, routes and the timeline. Each event and each SPF run also gets an ID.

**Native or container ospfd.** Every pane works the same for both. The driver decides where the socket, terminal, capture and kernel routes are.

**Auth and audit.** Every action passes the auth gate and is logged with its user. Today the user is the local admin.

## Inputs available today

| Source | What it gives |
| --- | --- |
| ospfd API (JSON over Unix socket) | `show.overview`, `show.neighbors`, `show.interfaces`, `show.database`, `show.routes`, `show.fib`, `show.spf`, `show.log`, `show.statistics`, `show.timers`, `show.configuration`, `config.load`, `config.replace`, `config.compare`, `config.commit`, `config.rollback`, `config.history`, `clear.neighbors` |
| Simulator HTTP API | `GET /api/state`, `/api/lsdb`, `/api/lsdb.txt`, `/api/lsa`, `/api/events`, `/api/topology`; `POST /api/refresh` (all), `/api/flush` (all), `/api/aging`, `/api/neighbor/start` and `stop`, `/api/links/:id/up`, `down`, `toggle`, `flap` |
| FRR | `vtysh -c "... json"` through `docker exec`; debug logs |
| Docker | exec, logs, start, stop, inspect |
| Kernel | captures with tcpdump in a node's namespace; routes with netlink or `ip route` |

New inputs are listed per pane and collected at the end.

## 1. Lab map (screen 1)

Shows the containers, the bridge, addresses, adjacencies by state (Full, 2Way, others), DR role, and the simulated area as a cloud behind `sim`. Badges show links down in the simulated area.

**Inputs.** Lab file (nodes, segments). Neighbor state from each driver. Simulator state.

**Actions.** Click a node to inspect it. Click the simulated area to get the simulator controls in the inspector. Show SPF tree. Expand the simulated area.

**Decisions.**
- Inspecting the simulated area gives the demo's features in place: its grid, click a link to take it down or up, flap, metric, refresh all LSAs, aging, flush, and a link to the full simulator screen.
- A clicked link stays selected, so flap and metric apply to it.

## 2. Device inspector (screen 1, right side)

Shows one node: kind, driver, location (container or VM host, socket path). Key numbers (LSDB size, routes, kernel routes, last SPF). Tabs: Neighbors, Interfaces, LSDB, Routes, Config, Logs.

**Inputs.** The node's driver, normalized: the same tables for ospfd, FRR and the simulator.

**Actions.** Open terminal, capture on interface, restart, clear neighbors.

## 3. Terminals (screen 1, bottom)

xterm.js tabs and splits: a shell in any node, `vtysh` on FRR, `ospf-cli` on ospfd.

**Inputs.** `docker exec` for containers. For native ospfd, the VM's namespaces, which needs the console container to run with host PID access.

**Decisions.**
- Commands typed in an FRR terminal trigger a re-read of its running config, so the config pane sees the change (pane 11).

## 4. Simulator (screen 5)

The simulated topology drawn as routers and links, like the demo dashboard.

**Shows.** The 5x5 grid and edge router. Links up, down or flapping. Routers that just reoriginated their LSA. A log of each action: the LSAs it originated and when frr and ospfd installed them.

**Actions.**
- Click a link to take it down or up. Click a router to inspect it.
- Router panel: its links with their own up or down buttons, router LSA sequence, refresh this LSA, flush this LSA, show in LSDB, flap with count and interval.
- Edge router: add externals, withdraw externals, refresh summaries.
- Top bar: refresh all LSAs, aging on or off, flush all, edit topology.

**Inputs.** Simulator API.

**New inputs needed.** Refresh one LSA, flush one LSA, change a link metric, add and withdraw externals and summaries at runtime, and a streaming event endpoint. Today the API refreshes and flushes all LSAs only.

**Decisions.** A link taken down here is runtime state, not config. It goes to the startup file only if you save it (pane 11).

## 5. LSDB compare (screen 4)

The databases of sim, frr and ospfd side by side.

**Shows.** Counts (total, identical, differing). For each differing LSA: the sequence on each router and why it differs, for example an update in retransmit, an LSA still in the request list, or an own LSA held by MinLSInterval. Below, the selected LSA's contents side by side with the differing lines marked.

**Actions.** Tabs: Differences, All, Router, Network, Summary, External. Snapshot. Show packets for this LSA.

**Inputs.** ospfd `show.database detail`, simulator `/api/lsdb`, FRR `show ip ospf database ... json`.

## 6. SPF runs (screen 6)

**Shows.**
- A chart strip per router: runs over time, bar height for compute time, amber when the hold timer delayed the run.
- A list of runs per router. ospfd exact; FRR from its JSON and debug log, without run numbers.
- The selected run: its triggers (LSA instances, clickable), a timing bar (wait, compute, FIB install) and its route changes.
- The convergence chain of one LSA instance: originated by sim, installed by frr, flooded, installed by ospfd, SPF on each, kernel routes. End to end time.

**Inputs.** ospfd `show.spf` and events. FRR JSON and debug log (to check what FRR 10.2 prints).

**Decisions.**
- SPF observability lives in ospfd. ospf-cli and the console both read it.
- In ospfd: each trigger records the LSA instance, its source (neighbor, self, MaxAge, neighbor state, commit) and arrival time. Each run records a number, first trigger, start, end, FIB done and the route diff, capped (for example 50 prefixes listed, the rest counted). LSAs and routes remember the run they triggered or that changed them. A ring of the last 100 runs.
- ospf-cli: timing columns in `show ospf log`, a new `show ospf log run N`, and links to the SPF run in route and database detail. IOS forms too.
- Live in the console, with the batching and freeze rules above. The console keeps hours of runs; ospfd keeps 100.

## 7. Routes, RIB and FIB (screen 8, low priority)

**Shows.** One row per prefix. RIB half: type, cost, next hops (ECMP as several), the LSA it came from. FIB half: kernel proto, next hop, since when. frr's cost for the same prefix. A status: in sync, pending install, connected (not installed), install failed, kernel only (stale), frr disagrees.

**Actions.** Tabs: Differences, All, Intra, Inter, External. Prefix lookup (longest match in RIB and kernel). Select a row for why it has that status and its history. Links to its LSA, the SPF run that set it, and its path on the map.

**Inputs.** ospfd `show.routes` and `show.fib`. FRR `show ip ospf route json`. The kernel of wherever ospfd runs.

**Decisions.** Priority low. A kernel route with proto ospfv2 and no RIB entry is shown as a bug.

## 8. Packet decoder (screen 2)

**Shows.** Packet list, field tree, bits panel, hex dump, Follow LSA.

**Actions and behavior.**
- Live capture from a chosen node and interface. Display filter. Pause. Save as pcap.
- Click a field in the tree: its bytes light up in the hex. Options, router LSA flags and DD flags show each bit.
- Hover a byte: every byte of its field gets a soft highlight, and so does its row in the tree. A line under the hex shows the field's offsets, name, value, and whether it is in the packet header or inside the LSA.
- Click a byte: its field becomes selected, in the tree, the hex and the bits panel.
- Follow LSA follows one LSA instance through originate, flood, install and ack. The field you point at lights up there too: type, Link State ID, advertising router and sequence in the header; sequence, age and checksum on the steps they explain. A packet only field dims the panel.
- Packet and LSA Fletcher checksums verified and shown.
- Optional cross check with `tshark`, with a count of fields that agree.

**Inputs.** tcpdump in the node's namespace. Our Ruby decoder.

**New inputs needed.** The decoder returns each field with its byte offset, length and bit mask. Every byte belongs to a field; reserved bytes are fields too.

## 9. Timers (screen 3)

**Shows.** One lane per timer, per device, interface and neighbor, on a shared time axis: hello, inactivity (dead), wait, LSA retransmit, SPF delay and hold, delayed ack, MinLSInterval, MinLSArrival, LSA refresh, MaxAge. A findings list. The table of ospfd's armed timers with time to fire.

**Actions.** Window 20 s, 1 min, 10 min. Follow live. Click a finding to mark its time span on every lane.

**Inputs.** ospfd exact, from a new timer API. FRR and the simulator measured from captures; FRR's JSON adds dead time remaining per neighbor.

**New inputs needed.** ospfd timer table: every armed timer with owner and next fire time.

**Decisions.** Checks flag hello or dead mismatch, near expiries, retransmit pile ups and SPF throttling. All nodes share the VM clock, so no time sync is needed.

## 10. Timeline (not mocked)

One correlated event stream across devices: state changes, floods, SPF runs, link flaps, commits. Scrub back in time. Arrows between linked events (an LSA install and the SPF run it triggered).

**Inputs.** Event streams from all drivers.

## 11. Config workbench (screen 7)

**Shows.**
- A lab bar: lab folder, git branch, how many nodes changed since the last save.
- One tab per node with a saved or unsaved badge.
- The running config next to a diff against startup, where it came from (terminal, commit, simulator), checkboxes per change, a commit message.
- Lab history: every save is a commit.

**Actions.** Save selected, revert selected, save all to lab, revert all, new branch. ospfd: commit check and rollback. History: diff and restore.

**Inputs.** ospfd config API and commit events. FRR `show running-config`. Simulator topology export. The lab folder.

**Decisions.**
- A lab is a folder: `lab.yml` plus one startup file per node (`ospfd.conf`, `frr.conf`, `sim.yml`), mounted read-write into the nodes. `examples/lab` becomes the template to copy. The console reads and writes only there.
- The lab folder is a git repo. Each save is a commit, so the lab has history, diffs, a branch per experiment and one click rollback. Recordings and scenarios name the lab version they ran on.
- Three configs per node: startup, running, and for ospfd the candidate.
- ospfd already writes its file on commit, so it shows as saved. FRR is saved by `write memory` or by the console writing the file. The simulator saves runtime state such as a link down only if asked.
- FRR changes are caught by re-reading its running config after each command typed in its terminal, plus a slow poll.
- A file changed on disk outside the console shows as a conflict to merge, never overwritten.
- Authentication keys are masked.
- The compose change (configs mounted read-write from a lab folder) comes first, before any config work.

## 12. Recording (not mocked)

Start, act, stop. The bundle holds logs, pcap, events and before and after snapshots, and replays in the timeline. It names the lab version it ran on.

**Open.** How long recordings are kept, and where.

## 13. Scenarios (not mocked)

Short scripts with assertions: flap link 3 five times, wait for Full, expect 293 routes, converge in under 1 s, change exactly 4 routes. Results kept as reports.

**Open.** Script format: Ruby DSL or YAML.

## 14. Lab lifecycle (top bar, not mocked)

Up, down, restart a node, health. Start order handled: the simulator Full before ospfd.

## New inputs, all panes

| Where | What | For pane |
| --- | --- | --- |
| ospfd | `events.subscribe`, streamed JSON lines | All live panes |
| ospfd | Timer table API | Timers |
| ospfd | SPF triggers, runs, route diff and links (see pane 6) | SPF runs, Routes |
| ospf-cli | `show ospf log` timing, `show ospf log run N`, SPF links in detail views | SPF without the console |
| Decoder | Field offsets, lengths and bit masks | Packet decoder |
| Simulator | Streaming events; refresh and flush one LSA; link metric; add and withdraw externals and summaries | Simulator, Lab map |
| Compose | Per node configs mounted read-write from a lab folder | Config workbench |
| ospfd | systemd unit for native runs | Lifecycle, logs |
| ospfd container | Socket on a volume | All ospfd panes |

## Priorities

| Pane | Priority |
| --- | --- |
| Lab map, inspector, terminals, simulator | First (phases 1 and 2) |
| Config workbench | Phase 3 |
| Packet decoder, timeline, recording | Phase 4 |
| Timers, SPF runs, LSDB compare | Phase 5 |
| Scenarios | Phase 6 |
| Routes, RIB and FIB | Low |
