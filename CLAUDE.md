# CLAUDE.md

Guide for AI agents working on ospfv2. Read this before changing anything.

## What this is

ospfv2 is a pure Ruby OSPFv2 implementation (RFC 2328) with two modes.

1. **The simulator**, `bin/ospfv2`. It forms one adjacency with a router
   under test (the DUT) and floods a synthetic area behind it: grids of
   routers, stubs, summaries, externals and TE LSAs, described in YAML or
   a Ruby DSL. It can take links down, flap them, refresh and flush LSAs,
   from a console, a web dashboard or its HTTP API.
2. **The router**, `bin/ospfd`, since 1.0. A real OSPFv2 router: areas,
   stub and NSSA, virtual links, authentication, SPF with ECMP, routes in
   the Linux kernel over netlink. It is configured in Junos terms with
   `bin/ospf-cli`, which talks to its management API.

It also ships the router labs that routescope, the lab console, runs, and
`ospfv2 capture`, the dissector routescope's packet pane reads.

The runtime uses the Ruby standard library and the owner's own gems,
brought in by path. The gemspec declares `irb` and `reline`, which left
the default gems, and `bfd4r`, the owner's BFD library: the `Gemfile` takes
it from `../bfd4r`, the image from the build context
`--build-context bfd4r=../bfd4r`, as isis takes datalink-socket. **Add no
other runtime gem.** routescope has its own gems; ospfv2 does not borrow
them. Owner's decision, 2026-11-21 (routescope `docs/design/bfd-clients.md`,
decision 1).

## The rule the rest follow from

**All router state lives on one event loop thread, and that loop reads
time from a clock it is given.** `infra/event_loop.rb` owns interfaces,
neighbors, the LSDBs and SPF. Socket threads hand packets in with `post`.
The CLI and the API use `call`, which waits for the answer. Timers come
from `after` and `every`, on the loop thread.

So the core needs no locks. Protocol code never calls `Time.now`; it asks
`loop.clock`. A test runs the loop on its own thread with `Clock::Fake`,
and minutes of protocol time take milliseconds:

```ruby
loop = OSPFv2::EventLoop.new(clock: OSPFv2::Clock::Fake.new)
loop.run_until(60) { a.full? && b.full? }
```

**This holds for `core/` and the daemon. It does not hold for the
simulator yet.** The simulator's stack is older: a thread per timer
(`infra/timer.rb`), a `Monitor` around the LSDB, and global counters.
`REVIEW.md`, "Worth rewriting next", items 3 and 4, has the plan. Do not
copy its patterns into `core/`. Do not "fix" them in passing either; it is
its own topic.

## Layout

The library lives under `lib/`. The module is `OSPFv2` and the gem is
`ospfv2`. Paths below are under `lib/ospfv2/` unless they say otherwise.

```
lib/ospfv2.rb        the simulator's stack: require 'ospfv2'
core.rb              the router core: require 'ospfv2/core'
version.rb           OSPFv2::VERSION, read by the gemspec

infra/               shared by both modes: event loop, clocks, scheduler,
                     transports (raw socket, and an in-memory Hub and
                     Loopback for tests), constants, the old Timer
core/                the router. instance.rb is one router; interface,
                     neighbor, area, virtual_link, lsdb, spf,
                     lsdb_topology (the LSDB as nodes, for BGP-LS),
                     spf_scheduler (RFC 8405), auth, bfd (which BFD
                     sessions to want, what a failure does), and wire.rb,
                     the packet codec; lsa.rb holds LSAs as raw bytes;
                     validation.rb names what ospfd finds wrong, with
                     the RFC text and each receive policy's action;
                     tlv.rb, opaque LSAs' TLVs (a registry, Unknown
                     kept), router_information.rb the RI LSA's,
                     extended.rb the extended prefix and link LSAs'
fault.rb             OSPFv2::Fault: opaque and SR LSAs wrong on purpose,
                     one per Validation rule; the simulator floods them
fib.rb, fib/         routes into the kernel: Manager decides, a backend
                     installs. netlink.rb on Linux, memory.rb in tests
config/              the Junos style configuration: schema.rb is the
                     tree of statements, tree.rb parses set lines,
                     model.rb checks a commit, policy.rb export policies
daemon.rb, daemon/   ospfd: the core on the real clock, the management
                     API (JSON lines on a Unix socket), views, events,
                     bfd.rb: the thread that polls bfd4r's BFD::Client
command_line/        ospf-cli: the command grammar, the shell, the
                     Junos and IOS formatters, the socket client

ie/, lsa/, lsa/tlv/  the simulator's codec: typed fields, LSAs, TE TLVs
packet/              the simulator's packets
ls_db/               the simulator's LSDB and its grid builders
neighbor/,           the simulator's Interface (one segment: hellos, flooding,
neighbor_sm/         the DR and BDR) and its Neighbors, one per adjacency, with
                     the RFC 2328 section 10 state machine as State objects
topology.rb          topology files, YAML or the Ruby DSL
simulator.rb         the simulator: builds the LSDB, applies live changes
cli.rb               bin/ospfv2: run, demo, show, export, check, init,
                     capture, lab new
console.rb           the simulator's irb console
web/                 the simulator's dashboard and HTTP API
dissect.rb, pcap.rb  ospfv2 capture: packets dissected to JSON lines

bin/                 ospfv2, ospfd, ospf-cli
test/unit/           unit tests, roughly by source folder
test/integration/    two simulators over the in-memory segment, and the
                     FRR interop tests in network namespaces
test/support/        the FRR namespace harness, netlink probe, and
                     routescope_vocabulary.rb: what routescope reads from ospfd
test/lab/            the lab tests, in shell: compose, clab, srl, bgp, bfd; pull.sh,
                     the image pulls CI makes, retried; bases.sh, the base
                     images tagged before a build, so Docker Hub is not asked
examples/            grid.yml, and links from the old template paths to
                     routescope/labs, for one release
routescope/labs/     the labs routescope runs, one ready-to-run folder
                     per lab, named for it; routescope-labs installs them
docker-compose.yml   the compose lab: sim, frr, ospfd, bird
Dockerfile           one image, an entrypoint per role, a test stage
docs/                user guide, lab commands, the routescope plan
REVIEW.md            the 2026 review: what was broken, what is next
```

**There are two codecs, and that is on purpose.** The simulator's
(`ie/`, `lsa/`, `packet/`) builds LSAs as objects and is lenient. The
core's (`core/wire.rb`, `core/lsa.rb`) was written for the router: strict
on decode, and it floods LSAs as the bytes it received. The simulator
borrows `Core::Lsa` only to describe an LSA in the shape ospfd's
`show.database` gives. Know which one a file uses before you change it.

## Design rules

Each of these is in the code. Follow it there, and in new code.

* **One loop, an injected clock.** See above. From another thread, wrap a
  call in `loop.call { ... }`.
* **Dependencies are passed in.** `Core::Instance.new` takes `loop:`,
  `random:`, `logger:` and `tracer:`. An interface takes a `transport:`.
  The daemon takes a FIB factory. Tests pass fakes; nothing reaches for a
  global.
* **A logger is a callable**, `->(level, message)`. bgp4r copied this
  shape from ospfv2. Do not add a logger class or a process wide log.
* **Events carry data, not only text.** `Instance::Event` has a `kind` and
  a `data` Hash, so the API, ospf-cli and routescope need not parse
  messages. A new kind of event goes into `api.info` and the README table.
* **Decode strictly, report the reason.** `Core::Wire.decode` raises
  `Wire::Error` with a reason. The interface counts it, logs it and raises
  a `drop` event. A bad LSA is skipped by SPF and said, not fatal
  (`spf_skipped`).
* **Tests never touch the host.** `Daemon` installs into `Fib::Memory`
  unless told otherwise; only `bin/ospfd` passes netlink. Transports in
  tests are `Hub` and `Loopback`.
* **ospfd touches only its own kernel routes**, the ones with its protocol
  id (89 by default). It refuses ids other daemons use, and never
  overwrites another route to the same prefix at the same metric.
* **The configuration has one source of shape.** `config/schema.rb`
  declares it, and the parser, completion and help all come from there.
  Add a statement to the schema, not to the shell.
* **Junos forms print Junos style, IOS forms print IOS style.** A new show
  command gets both forms where both routers have one.
* **Everything is under `OSPFv2`.** Files load with `require_relative`.
  No patches on core classes such as `Class` or `IPAddr`. A few old
  helpers on `String` and `Symbol` remain (`REVIEW.md` item 7); add none.
* `# frozen_string_literal: true` at the top of every Ruby file.

## RFCs

RFC 2328 is the base, and almost every citation in the code is to it. The
others the code cites:

| RFC | What | Where |
| --- | --- | --- |
| 2328 | OSPF version 2 | everywhere |
| 3101 | NSSA, type 7 LSAs and their translation | `core/`, config |
| 3509 | what makes an area border router | `core/spf.rb`, `core/instance.rb` |
| 5709 | HMAC-SHA authentication | `core/auth.rb` |
| 8405 | SPF back-off | `core/spf_scheduler.rb` |
| 9552 | BGP-LS: the LSDB as nodes for a Producer | `core/lsdb_topology.rb` |
| 5880 | BFD; its timers are in microseconds | `core/bfd.rb`, through bfd4r |
| 5882 | BFD clients: 4.1 no waiting, 4.2 AdminDown, 10.1.2 OSPF | `core/bfd.rb` |
| 5250 | opaque LSAs | `lsa/opaque.rb`, dissector, `core/validation.rb` |
| 7684, 7770, 8665 | extended LSAs, Router Information, SR | `core/validation.rb`, `fault.rb`, `core/tlv.rb`, `core/router_information.rb`, `core/extended.rb` |
| 3630 | TE LSAs | `lsa/traffic_engineering.rb`, `lsa/tlv/` |
| 4915 | multi-topology metrics | `ie/`, `lsa/external.rb` |
| 1071 | the packet checksum | `core/wire.rb`, `core/auth.rb` |

Also cited in passing: RFC 1583 (the compatibility flag), RFC 1793
(DoNotAge), RFC 4811 (the DD R bit, ignored), RFC 3623 and 4970 (opaque
type names), RFC 791 (the dissector's IPv4 header). RFC 7474 is cited as
**not implemented**: without it a replayed packet can be accepted after a
restart.

Not implemented, so do not claim them: graceful restart (RFC 3623),
RFC 7474. The simulator has null authentication only, no DR election and
one neighbor per process.

**Cite the RFC section in a comment when you implement or fix protocol
logic.** Open the RFC and check the section number against its text; do
not write one from memory.

## Labs, the simulator and routescope

routescope is a web console over ospfv2's labs, in its own private repo,
`jeanmichel-gh/routescope`, cloned beside this one. It does not build
labs. It drives labs that docker compose or containerlab bring up. The
plan and its decisions are in `docs/console-plan.md` and
`docs/console-panes.md`.

**A lab is a folder**: `lab.yml` or `NAME.clab.yml`, plus one config per
node, an `ABOUT.md` and a `.gitignore` for runtime state. The labs live in
`routescope/labs/<lab>/`, named for the lab: ospf-lab, ospf-ring,
ospf-srl, bgp-ibgp, ospf-bgp, isis-bgp, ospf-bfd. Each is complete as committed; no
step generates files. routescope's `routescope-labs install ospfv2/<lab>`
copies one into `~/labs/ospfv2/<lab>` (routescope's
`docs/design/labs-layout.md`). `ospfv2 lab new DIR` stays one release: it
copies from `routescope/labs/`, makes a git repository, and prints the
`routescope-labs` line. Flags pick the lab: none for the compose lab,
`--containerlab`, `--srlinux`, `--bgp`, `--ospf-bgp`, `--isis-bgp`; ospf-bfd,
newer, has no flag (`CLI::LABS`). The
old `examples/` paths are symlinks for that release. routescope runs
compose labs with this repo's `docker-compose.yml`.

**What routescope reads from ospfv2**, one driver per node kind:

* `ospfd`: the management API, JSON lines on `/run/ospfv2/ospfd.sock`.
  `api.info` gives the version and methods, so the console can grey out
  what an older ospfd lacks.
* `ospfv2-sim`: the simulator's HTTP API, `/api/...` in `web/server.rb`.
  A POST needs the `X-OSPFv2: 1` header.
* Captures: `ospfv2 capture` in the node's namespace, one JSON line per
  packet, every field with its offset, length and mask.

**These APIs are the contract, and changes to them are additive only.**
New methods and fields are fine. A rename or a removal goes through a
deprecation, so ospfv2 can always merge first without breaking the
console. A feature that spans both is two linked pull requests, ospfv2
first. A field that routescope reads is worth a test here.

The labs hold more than OSPF. The BGP and IS-IS labs
(`routescope/labs/bgp-ibgp`, `ospf-bgp`, `isis-bgp`) are FRR and BIRD; the bgp4r lab lives in
bgp4r's own docs. `docs/lab-commands.md` is the runbook for all of them.

## Testing

Ruby 3.2, 3.3, 3.4 and 4.0 are tested in CI; 3.2 is the floor for
every router that takes bfd4r (the owner, 2026-11-21). Tests use
test-unit. bfd4r must be checked out beside this repository, at
`../bfd4r`, for `bundle` and for the image.

The full unit suite:

```sh
bundle exec rake test:unit
```

It needs no root and no network, and takes under a minute. Measured
2026-11-21 on Ruby 3.3.8: 724 tests, 7380 assertions, all passing, with
one omission (a test that needs root), in 46 seconds. Copy counts out of a run, never
work them out.

The other tiers:

```sh
bundle exec rake test                        # unit and integration; what CI's test job runs
bundle exec rake test:integration            # two simulators over the in-memory segment
bundle exec ruby -Ilib -Itest test/unit/core/spf_test.rb   # one file
sudo -E env "PATH=$PATH" OSPFV2_FRR=1 bundle exec ruby -Ilib -Itest test/integration/frr_interop_test.rb
test/lab/lab_test.sh                         # the compose lab end to end; Docker, minutes
test/lab/bfd_test.sh                         # the BFD interop lab with FRR, and its gate; containerlab
```

The FRR tests need root, iproute2 and FRR, and run only with
`OSPFV2_FRR=1`. Without it they skip: `rake test` measured 762 tests, 25
of them omitted, on the same day. The lab scripts replace a lab you
are running; start yours again afterwards. CI runs every tier, in
`.github/workflows/ci.yml`; a draft pull request runs the unit tests
only, and the rest once it is marked ready.

**AppArmor confines FRR's ospfd on newer Ubuntu.** Ubuntu's `apparmor`
package ships `/etc/apparmor.d/ospfd` (26.04 does, 24.04 does not). It
allows only FRR's default paths, such as `/run/frr/ospfd.pid`, and the
FRR tests run ospfd in a pathspace, `/run/frr/<name>/`. So ospfd exits
with `Can't create pid lock file ... (Permission denied)` and every FRR
test fails; zebra has no profile, so zebra starts and ospfd does not.
`FrrLab.start_daemon` puts the daemon's output and the profile in its
error. CI's `ubuntu-latest` became 26.04 between 6 and 9 November 2026,
so the `interop-frr` job unloads the profile before the tests; the
runner is thrown away after the job. isis does the same for isisd. On a
machine of yours:

```sh
sudo grep '^ospfd ' /sys/kernel/security/apparmor/profiles   # ospfd (enforce)
sudo apparmor_parser -R /etc/apparmor.d/ospfd                # unload until reboot
sudo apparmor_parser -r /etc/apparmor.d/ospfd                # load it again
```

The tests do not unload it for you: a test should not change a host's
security settings.

* New behaviour needs a test. A fix needs a test that failed before it.
* Test the core on the fake clock. Some simulator tests wait on real
  time, because its timers are threads; do not copy that into a core
  test.
* Run a file you changed on its own and in the suite. A file that does
  not require what it names passes in the suite and fails alone.
* A test method defined after `private`, or defined twice, never runs and
  nothing says so. If a count looks low, compare it against
  `grep -c 'def test_'`.
* **When you add a test for a fix, break the fix and watch the test
  fail.** A sabotage that passes means the sabotage missed, or the test
  is weak. Check which.

## Rules for agents

* Work on a branch named `claude/<short-topic>`. Never push to master.
* One topic per pull request. Small diffs.
* Run the full unit suite before opening a pull request. All tests must
  pass.
* Update a pull request's branch by rebasing on `origin/master`, then
  `git push --force-with-lease`.
* **A design spec comes first.** Write it in `docs/design/<topic>.md`, and
  get it approved before coding starts.
* Write in plain, short sentences: code comments, docs, commit messages,
  pull requests.
* Do not delete or weaken existing tests to make a change pass.
* If you find a bug you are not fixing, say so in the pull request.
* **Work out what the code was built to do before concluding it is wrong.**
  A shape that looks odd is more often a decision whose reason was never
  written down than a defect. Say "I do not know why this is like this"
  rather than "this is wrong" until you have answered the first.
* **Measure rather than recall.** Counts, timings, what a router does. If
  a command can print it, do not write it in prose. If prose must carry
  it, say when it was measured.
* Keep this file true in the pull request that makes it false. Keep the
  README tables true too: the commands, the API methods, the event kinds.

## Sharing ospflab with other sessions

Many sessions work on ospflab at once, each on its own topic. These
rules keep one from undoing another's work: rebuilding an image under a
lab, stopping a gate halfway, editing a lab's files. The reasons are in
routescope's `docs/design/shared-vm.md` (approved 2026-11-22).

1. **An image tagged `:latest` is master.** `~/routescope/tools/vm-update.sh`
   builds it from master; an image vm-update does not build (`vtep4r`
   today) is built from its checkout in `~` on master. To run a branch or
   a commit, build it under its own tag, `NAME:SHORTSHA`, with
   `~/routescope/tools/vm-build REPO REF --for PURPOSE`, and remove it with
   `--rm` when its runs are done (routescope `docs/vm-build.md`). Never
   build `NAME:latest` from a branch.
2. **The checkouts in `~` stay on main or master.** vm-update pulls them.
   Branch work happens in worktrees, never in `~/REPO`.
3. **Do not edit `~/labs`.** To run a lab on another image or with other
   files, `routescope-labs fork LAB NAME` copies it to `~/labs/local/NAME`
   under a lab name of its own, so its containers do not collide with the
   original's. Edit the copy, and `routescope-labs retire NAME` when done.
4. **Take the VM's lock around what disturbs others**,
   `~/routescope/tools/vm-lock` (routescope `docs/vm-lock.md`):
   - `exclusive` to restart Docker or routescope, or to stop or redeploy
     a lab you did not start. vm-update takes it itself.
   - `shared` for a gate or a scenario run.

   Run it as the VM's user, with `sudo` inside the command. It waits up
   to 15 minutes; when it gives up (exit 75), ask the user before trying
   again.
5. **A gate's containers have the names of routescope's copy of its
   lab**, `clab-LAB-NODE`. Until the gates run under a name of their own,
   stop routescope's copy through routescope before a gate, and start it
   again after, both under the lock.
6. **A lab run outside routescope** (one only on a branch, deployed by
   hand) is named in `~/vm-changes.md`, with the folder it came from.
7. **Each entry in `~/vm-changes.md` names the session** that made it.

## Where the work is going

A plan that spans more than one session lives here, with its status, so
the next reader sees the direction without rebuilding it from a chat.
**Update the status in the pull request that moves it.** Status measured
2026-11-13 at `ccad43f`, by grepping the code. The plan across the four
repositories (routescope, ospfv2, bgp4r, isis) is in routescope's
`CLAUDE.md`, "Where the work is going". This section is ospfv2's part.

### What routescope asked of ospfv2

From `docs/console-plan.md`, "Changes needed in ospfv2", and
`docs/console-panes.md`, "New inputs, all panes".

| Change | Status | Where |
| --- | --- | --- |
| `events.subscribe` on the ospfd API | Done | `daemon/api.rb:20-41` |
| Timer table, `show.timers` | Done | `daemon/api.rb:51` |
| Decoder field offsets, lengths, masks | Done | `dissect.rb`, `ospfv2 capture` |
| SPF triggers, runs, FIB done, route diff, back links | Done | `core/instance.rb:43-78` |
| ospf-cli `show ospf log` timing, `show ospf log run N`, IOS forms | Done | `command_line/grammar.rb:148` |
| Per node configs mounted read-write from a lab folder | Done | `docker-compose.yml`, `routescope/labs/ospf-lab` |
| ospfd socket on a volume | Done | `docker-compose.yml:117`, `ospfd-run` |
| `api.info`, version and methods | Done | `daemon/api.rb:75`. routescope asks it from jeanmichel-gh/routescope#129 on. |
| `show.topology` and the `topology` event | Done | `docs/design/ospf-topology.md`, #48, #49 |
| Recorded API fixtures in `test/fixtures/api/` | Replaced | routescope's `docs/design/api-contract.md`: `test/support/routescope_vocabulary.rb` is what routescope reads, copied from its `rake vocabulary`; `test/unit/daemon/routescope_vocabulary_test.rb` holds ospfd's API to it. Refresh the copy when routescope reads something new. |
| systemd unit for a native ospfd | Not started | No unit file in the repo |
| Simulator: link metric | Done | `web/server.rb:107` |
| Simulator: refresh or flush one LSA | Done | `Simulator#lsa_refresh`, `#lsa_flush`; `POST /api/lsa/refresh`, `/flush`. `docs/design/sim-lsa-actions.md` |
| Simulator: add and withdraw externals and summaries at runtime | Done, the topology's own | `POST /api/routes/withdraw`, `/advertise`; no new prefixes, by the owner's choice |
| Simulator: a streaming event endpoint | Done | `GET /api/events/stream`; `GET /api/info` lists the routes. routescope reads neither yet |

### BFD, step 6c of routescope's `docs/design/bfd-clients.md`

* Built: `bfd-liveness-detection` on an interface, `Core::Bfd`, the
  `bfd` field in `show.neighbors` and the `bfd` event kind, the image
  with bfdd4r, and the interop lab `routescope/labs/ospf-bfd` with FRR.
  The simulator keeps no BFD.
* Not built: Junos's other options (`full-neighbors-only`,
  `minimum-receive-interval`, `transmit-interval`, authentication), ospf-cli
  forms that show the BFD session, BFD on virtual links.

### ospf-cli

* **Issue #16, `edit`, `up` and `top` in configuration mode. Not
  started.** ospf-cli takes complete `set` statements only. The issue
  lists what to add and the tests.

### The simulator's debts, `REVIEW.md` "Worth rewriting next"

These are about the simulator's older stack (`ie/`, `lsa/`, `ls_db/`,
`neighbor/`, `infra/timer.rb`). `core/` was written new and does not have
them (Decisions, 2026-10-26). None is started in the simulator.

1. `Common#set`, the reflective constructor. Still there,
   `infra/ospf_common.rb:170`.
2. The DD exchange as a table of events by states, and the 2-Way state.
   `neighbor/recv_database_description.rb` is still one conditional.
3. Timers: one thread per timer, `infra/timer.rb`. `core/` has the
   scheduler and the injected clock; the simulator does not.
4. Global state: the `LSDB::Link` registry, the DD sequence number
   (`packet/database_description.rb:128`), the shared aging clock.
5. Done: the DD paging cursor is each adjacency's (`Neighbor::Cursor`),
   `docs/design/sim-dr-bdr.md`.
6. Retransmission per neighbor and per LSA, and the LSU size from the MTU.
7. Core extensions still global: `to_camel`, `hexlify`, `to_klass`,
   `to_shex` in `infra/ospf_common.rb`.
8. Features. MD5 and HMAC-SHA authentication and NSSA are in `core/`, so
   ospfd has them; the simulator has neither. TE LSAs in the topology
   file, several neighbors from one simulator, and pcap of what it sent
   are not started.

### The simulator and a BDR: built

Measured 2026-11-13: on a segment with a DR and a BDR, the BDR never
reached Full with the simulator (24 of 29 runs stuck; the rest passed by
timing). `docs/design/sim-dr-bdr.md`, approved and built: an `Interface`
owns the segment and each adjacency is a `Neighbor`, with the DR and the
BDR. Item 5 above is done; item 6 is done for retransmission per
neighbor, not for the LSU size. It replaces the "start order" item in
routescope's plan: the user guide's ExStart line was this bug.

### SR in OSPF, P7 in routescope's `docs/protocol-coverage.md`

Specified in `docs/design/sr-ospf.md` (approved 2026-11-25, #65). Its
nine open questions keep the draft's answers until the owner changes
them. The build order:

| Step | What | Status |
| --- | --- | --- |
| 0 | `validation.rb`, `OSPFv2::Fault`, `/api/fault` on the simulator | Done, #68 |
| 1 | Opaque LSAs (RFC 5250): the O bit in DDs, types 9 to 11, a link-scope database | Done, #69 |
| 2 | Router Information (RFC 7770), with SR-Algorithm, SRGB and SRLB | Done, #70 |
| 3 | Extended prefix and link LSAs (RFC 7684) | Done, #71: codec and reading; origination is step 4's |
| 4 | SR-MPLS (RFC 8665): SIDs, the label table, label routes by netlink | Configuration and origination: this change. Calculation and API, then forwarding, not started |
| 5 | The simulator sends SR LSAs | Not started |
| 6 | TI-LFA | Its own spec, later |

### Noted for later, from the owner, 2026-11-13

Not designed yet; routescope's `CLAUDE.md`, "Where the work is going",
holds the full note.

* One CLI for OSPF, IS-IS and BGP in Cisco syntax (IOS XE is the likely
  OS, once its public command references are checked). `ospf-cli` already has IOS and Junos forms; it would join `bgp4r-cli` and `isis-cli` behind one shell. The owner found odd things in the `ospf-lab` topology: review it first.
* CI runs only the jobs a change's paths need. Not done. Done on
  2026-11-13, a first step: each commit runs once (a pull request through
  pull_request, master through push), and a newer push cancels a pull
  request's older run.
* Review and document every lab in `routescope/labs/`.
* A change to documents alone may have its own pull request: CI no
  longer costs money (2026-11-15, the repository is public). A small
  note may still ride with a code change on the same topic.

### Open questions

* `ospf-topology.md`: whether `show.spf` should carry `reached`. Left
  out unless someone asks.

## Decisions

Architecture decisions, dated, with the premise each came from. A later
decision may change one.

**2026-10-24. A gem under `lib/ospfv2`, standard library only.**

* `ostruct`, `observer` and `logger` were dropped as they left the default
  gems. Monkey patches on `Class` and `IPAddr` moved under `OSPFv2`.
* Premise: a library that runs in a minimal container and next to other
  gems must not claim top level paths or need a gem install to start.

**2026-10-26. The router is a new core, not the simulator grown up.**

* `core/` has its own codec, event loop and scheduler. The simulator kept
  its stack.
* Premise: the simulator's thread per timer and global state could not be
  tested on a fake clock, and a router has to be. `REVIEW.md` lists the
  simulator's debts.

**1.0, 2026-10-27. ospfd installs routes over netlink, in pure Ruby.**

* `fib/netlink.rb` packs rtnetlink messages through Ruby's `Socket`. No
  `ip` binary, no native extension. The manager speaks route operations,
  so another backend can sit behind it.

**2026-11-21. BFD through bfd4r; the owner's gems by path.**

* ospfd asks `bfdd4r`, one per network namespace, for its sessions,
  through bfd4r's `BFD::Client`. `core/bfd.rb` holds the rules on the
  loop; `daemon/bfd.rb` is the one thread that polls the client and
  posts what it hears. The image's entrypoint is `with-bfdd4r`.
* "Standard library only" became "and the owner's own gems, by path".
* Premise: one BFD daemon and one client for isisd, ospfd and bgp4rd
  (routescope `docs/design/bfd.md`, `bfd-clients.md`), so each router
  does not carry its own BFD.

**routescope's decisions, from `docs/console-plan.md`.** routescope is a
separate repo. ospfv2 gets the APIs it needs as normal features. SPF
observability lives in ospfd, and ospf-cli and the console both read it.
ospfv2 stays standard library only, with the owner's own gems since
2026-11-21 (above).
