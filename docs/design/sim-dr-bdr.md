# The simulator adjacent to the DR and the BDR

Status: approved 2026-11-13, with the three open questions answered as
proposed. Built in this pull request.

## The problem

On a broadcast segment the simulator keeps one adjacency, with the DR.
RFC 2328 section 10.4 asks for two: "On broadcast and NBMA networks, all
routers become adjacent to both the Designated Router and the Backup
Designated Router." So when the segment has a BDR, the BDR never reaches
Full with the simulator.

This was built that way on purpose. The simulator was written to talk to
one router under test, and the README says so: "Not supported: ... DR
election by the simulator, ... more than one neighbor per process." The
shipped `ospf-lab` stays inside that limit: the simulator and ospfd both
run at priority 0, so FRR is DR and there is no BDR.

### Measured

On the VM, 2026-11-13, ospfv2 at ccad43f (the `ospfv2:latest` image
checked file by file against master) and FRR 10.2.1. 45 runs of a copy of
`ospf-lab`, in five groups. A run passes when every router that should be
adjacent to the simulator says Full within 120 s.

| Case | Runs | Passed |
| --- | --- | --- |
| Shipped config: FRR DR, no BDR | 13 | 13, Full in 7 to 20 s |
| ospfd priority 1, no FRR: ospfd DR, no BDR | 3 | 3 |
| ospfd priority 1 with FRR: a DR and a BDR | 29 | 5 |

Of the 24 that failed, the BDR stayed in ExStart (or in Exchange, with
packet loss) for the whole run. The five that passed did so by timing:
the simulator went Full with FRR first, then moved its one adjacency to
ospfd, and FRR still said Full because nothing told it otherwise.

In a stuck run, FRR (BDR, 2.2.2.2) sends its first DD packet (I, M and
MS set) every 5 seconds. The simulator, Full with the DR, drops each one
in `recv_database_description.rb:27` and says so only at debug level.

Routes still reach every router, because LSAs flood through the DR: the
three routers held the same LSA count in every run. That is why nobody
saw it. The symptom in `docs/user-guide.md` ("The simulator loops between
ExStart and Exchange ... It was not Full before `ospfd` came up") is
most likely this, seen from the BDR.

## What exists

Read at 2b03842. Paths are under `lib/ospfv2/`.

- **One `Neighbor` is the whole simulator side.** `Simulator` builds one
  (`simulator.rb:421`) and asks it for state, floods through it, and
  draws it as the `dut` node and edge (`simulator.rb:307-309`).
- **`Neighbor` mixes the interface and one adjacency.** It owns the
  transport, the event thread, the hello, the hello timer, the refresh
  timer, and also the state, the DD sequence numbers, the request list
  and the inactivity timer (`neighbor/neighbor.rb:79-100`, `:184-198`).
- **The choice of peer.** `adjacency_peer?`
  (`neighbor/recv_ospf_packet.rb:53`) takes the first router heard, and
  moves to the DR when one shows up. Any other router is only added to
  our hello, so it sees 2-Way. `from_peer?` drops DD packets from
  anyone else.
- **State the LSDB holds for one adjacency only:**
  - `offset`, the DD paging cursor (`ls_db/link_state_database.rb:95`,
    used in `packet/database_description.rb:293-295`). `REVIEW.md` item
    5 names it.
  - one acked flag per LSA (`ls_ack`, `all_not_acked`, `:157`, `:245`).
    RFC 2328 13.6 keeps a retransmission list per adjacency.
  - `reset` (`:217`), run on every ExStart (`neighbor_sm/exstart_state.rb`),
    marks every LSA acked and rewinds the cursor.
- **Hellos.** Our hello copies the DR from the last hello heard
  (`neighbor_sm/neighbor_state.rb`, `recv_hello`). Its BDR field stays
  0.0.0.0. Priority is 0 (`neighbor.rb:337`).
- **The interface link** (RFC 2328 12.4.1.2): a transit link to the DR
  once the one adjacency is Full (`simulator.rb:447`).
- **Tests.** `Transport::Hub` is an in-memory segment
  (`infra/transport.rb:102`). `test/integration/adjacency_test.rb` runs
  two `Neighbor`s on it, and `core_interop_test.rb` runs the simulator
  against the core router on an `EventLoop`.
- **routescope reads** `/api/state`: `neighbor` (`router_id`, `state`,
  `designated_router`, `address`, `neighbor_ip`, `neighbor_router_id`)
  and the `dut` node and edge in `graph`. Its `Sim` driver
  (`drivers.rb:991-1072`) assumes one neighbor, the DR.

## Proposal

The simulator stays a DROther at priority 0. It runs no election and
never becomes DR or BDR. It forms an adjacency with the DR and one with
the BDR, and stops at 2-Way with everyone else.

### 1. Split the interface from the adjacencies

- **`Neighbor` stays the adjacency**: the state machine, DD sequence
  numbers, request list, inactivity timer, DD retransmit timer.
- **`Neighbor.new` with no `interface:` still gives a whole simulator
  side**, as it does today for the simulator, the CLI's demo peer and the
  tests: it builds an `Interface`, which answers the same public methods
  (`start`, `state`, `full?`, `flood`, `hello`, `neighbor_ip`, ...) for
  its adjacency with the DR. So the point-to-point and one-neighbor
  paths, and their tests, do not change.
- **A new `Interface`** (`neighbor/interface.rb`) holds what is one per
  segment: the transport and its event thread, the hello and its timer,
  the DR and BDR as the other routers' hellos name them, the refresh
  timer, flooding, and the lock.
- **Receive.** The interface reads each packet once and hands it to the
  adjacency of the router that sent it, by source address. A hello from
  a router with no adjacency is listed in our hello (2-Way, as today).
- **No DR yet.** While no hello names a DR, the simulator keeps today's
  rule: it is adjacent to the first router it hears. Two simulators on a
  segment, both priority 0, still reach Full as they do today. RFC 2328
  would leave them at 2-Way; the tests rely on today's behaviour.
- **Whether to be adjacent** (RFC 2328 10.4) is decided when a router
  first sees us (2-Way) and again when the DR or BDR changes. The router
  named DR or BDR gets an adjacency. One that stops being DR or BDR
  loses it: its `Neighbor` is killed, as `kill_nbr` does today.
- **Our hello** names the DR and the BDR the others agree on, rather
  than leaving the BDR at 0.0.0.0. Hellos still go to AllSPFRouters.

### 2. Move per-adjacency state off the LSDB

- **The DD cursor** becomes the adjacency's. `DatabaseDescription` takes
  a cursor argument in place of reading `ls_db.offset`. `offset` stays
  as a deprecated reader, so nothing outside breaks.
- **How retransmission works today**: each LSA has one flag
  (`Lsa#retransmit` and `#ack`). Every 5 seconds the adjacency floods
  every LSA not acked to AllDRouters. That is also how a refreshed LSA
  first goes out.
- **Retransmission** becomes per adjacency (RFC 2328 13.6: "LSAs flooded out an adjacency are placed on the adjacency's Link state retransmission list"): each
  `Neighbor` keeps the keys of LSAs it flooded and its neighbor has not
  acked. An ack clears them only for its sender. A retransmission goes to
  that neighbor's address (13.6). Flooding stays one multicast to AllDRouters.
- **`LinkStateDatabase#reset`** no longer runs on ExStart. ExStart clears
  only that adjacency's cursor and lists.
- **The LSA's flag** stays, and keeps meaning "still to be sent": it is
  cleared once every adjacency in Exchange or later has acked that
  instance. An adjacency entering ExStart counts every LSA as acked by
  it, since the exchange will describe them; this is what `reset` did.
  `lsdb_rows`' `acked` column reads the flag, as today.

### 3. The simulator

- **One `Interface`, and its `Neighbor`s.** `Simulator#start`, `stop`,
  `running?` and `synchronize` go to the interface. `flood` goes to the
  interface, which sends it if any adjacency is Full.
- **The interface link** keeps following RFC 2328 12.4.1.2: a transit
  link once the adjacency with the DR is Full, a stub before.
- **One refresh timer** per simulator. Today each `Neighbor` has one,
  and two would refresh twice.
- **Events** name the neighbor: `2.2.2.2 exstart -> exchange (...)`.

### 4. `/api/state`: additive

- `neighbor` keeps its keys and meaning: the adjacency with the DR, or
  the only one on point-to-point.
- **New `neighbors`**: one row per router heard, `{ router_id, address,
  role: DR | BDR | DROther, state }`. A DROther row says `2way`.
- `graph` keeps the `dut` node and edge for the DR. Open question 1 is
  how to draw the BDR.
- routescope reads `neighbors` when present, in its own pull request
  after this one merges. Until then it shows what it shows today.

## Not in this work

- The simulator as DR or BDR, and an election of its own.
- More than one interface per simulator, and NBMA.
- `REVIEW.md` items 1, 2, 3, 4 and 7: the reflective constructor, the DD
  state table, one thread per timer, and the global counters. The DD
  code gets the cursor and the per-sender routing only. `REVIEW.md` item
  2's missing 2-Way state is not added: a router we are not adjacent to
  has no `Neighbor`, which is what 2-Way means here.
- The core router (`core/`). It already forms DR and BDR adjacencies.

## Tests

Each fails on master before the change, except the ones marked
unchanged.

- **On the `Hub`, with the core router.** The simulator and two core
  routers, priorities 1 and 2. Both core routers reach Full with the
  simulator, and their LSDBs match its.
- **Two exchanges at once.** The same, with a database large enough to
  need several DD packets each (the 12x12 grid and 3000 externals
  measured above). Both finish with every LSA.
- **Loss.** The `Hub` drops one LSA ack from the BDR. The simulator
  retransmits that LSA to the BDR only, and stops once it is acked.
- **Roles change.** The DR stops: the BDR becomes DR and keeps its
  adjacency, a new BDR is elected and gets one, and our hello names the
  new DR. The interface link follows, since `on_state_change` fires when
  another adjacency becomes the DR's even if the state stays Full.
- **A DROther stays at 2-Way.** A third core router at priority 0 lists
  us and we list it. No DD packet goes to it.
- **Unchanged:** every test in `test/unit/neighbor/`, `test/unit/sim/`,
  `adjacency_test.rb` and `core_interop_test.rb`.
- **The gate, on the VM.** The 45-run measurement above, run again: all
  29 runs with a BDR pass, every router holds the same LSA count, and the
  13 shipped-config runs still pass in the same time.

## Documents

- README: "more than one neighbor per process" becomes "adjacencies with
  the DR and the BDR only; the simulator never becomes DR or BDR".
- `docs/user-guide.md`: the ExStart troubleshooting line is replaced by
  what was measured.
- README's API table gains `neighbors`.
- `routescope/labs/ospf-lab/ABOUT.md`: why the priorities are 0, and that
  a BDR now works.
- `CLAUDE.md`, "Where the work is going": this item, and `REVIEW.md` item
  5 marked done.

## Open questions

1. **Drawing the BDR.** Keep `dut` for the DR and add a second node,
   `dut-bdr`, with its own edge? Proposed: yes. routescope's map already
   draws `dut` from the graph, so a second node needs no change there.
2. **ospf-lab's default.** Should the shipped lab get a BDR (ospfd at
   priority 1), so every run exercises this? Proposed: no. Keep the lab as
   it is, and add a scenario or a second lab later as part of the lab
   review.
3. **Unicast retransmits.** RFC 2328 13.6: "retransmissions are sent
   directly to the neighbor's IP address." Today they go to AllDRouters.
   Proposed: unicast, as the RFC says.

## Work

One pull request in ospfv2. This specification is its first commit. It
also carries the plan commits already on the branch, so they need no CI
run of their own. Then a small routescope pull request reads `neighbors`.

## As built

- `Interface#change_state` drives the adjacency with the DR, making one
  if there is none. The simulator's unit tests put the one adjacency in
  a state this way, and they pass unchanged.
- With no adjacency, the segment's state is `attempt` once started and
  `down` once an adjacency is lost, as the one `Neighbor`'s was.
- The DR and BDR come from the live routers' hellos, and a router that
  names itself is believed first. Without that, during a DR change the
  hellos disagree for a dead interval, and the BDR's adjacency was
  dropped in the test.
- An LSA of ours echoed back by a neighbor is an ack from that neighbor
  only: `LinkStateDatabase#recv_link_state_update` takes an
  `implied_ack:` hook. RFC 2328 13.5, Table 19: a BDR does not ack a
  DROther's update, so one unicast retransmission to the BDR, which it
  then acks directly, is expected.
- The FRR tests in network namespaces run the core router, not the
  simulator, so they do not cover this change.

### The gate, measured

On the VM, 2026-11-13, the same 45 runs with the simulator from this
branch (image `ospfv2:sim-dr-bdr`), ospfd and FRR as before.

| Case | Runs | Passed before | Passed after | Slowest after |
| --- | --- | --- | --- | --- |
| Shipped config: FRR DR, no BDR | 13 | 13 | 13 | 14 s |
| ospfd priority 1, no FRR: no BDR | 3 | 3 | 3 | 2 s |
| A DR and a BDR | 13 | 2 | 13 | 16 s |
| A DR and a BDR, 12x12 grid and 3000 externals | 8 | 3 | 8 | 16 s |
| A DR and a BDR, 5 to 10% loss, 10 to 20 ms delay | 8 | 0 | 8 | 23 s |

In every run each router held the same LSA count. The shipped config's
cold start went from 18 to 20 s to 13 to 14 s.
