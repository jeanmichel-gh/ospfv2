# Code review and 2026 refresh

This note covers what the code does, what was broken, what changed, and which parts
are worth rewriting next. Line counts are for `lib/` only.

## What the code is

An OSPFv2 implementation built for one job: be a convincing neighbor to a real router
and feed it a large, synthetic link state database.

| Layer | Where | Role |
| --- | --- | --- |
| Information elements | `ie/` (19 files) | Typed fields: Id, LsType, LsAge, SequenceNumber, Metric, Options... Each knows how to encode, parse and print itself. |
| LSAs | `lsa/`, `lsa/tlv/` | Router, Network, Summary, ASBR Summary, AS External, TE opaque LSAs and TE TLVs. Fletcher checksum in `Lsa`. |
| Packets | `packet/` | Hello, DD, LS Request, LS Update, LS Ack, with the OSPF header checksum. |
| LSDB | `ls_db/` | A Hash keyed by `[type, ls_id, advr]`. Builders for grids, p2p links, stubs. Junos and IOS style rendering. |
| Neighbor | `neighbor/`, `neighbor_sm/` | The RFC 2328 section 10 state machine as State objects, plus the DD exchange, flooding, acks and retransmission. |
| Infra | `infra/` | Raw socket transport, timers, constants, option parsing, helpers. |

The encoding layer is solid. Packets and LSAs round-trip byte for byte, and the test
vectors match captures from real routers. The protocol engine is the weaker part: it
works on the happy path, and most of the bugs below sat in error and edge paths.

## Bugs found and fixed

### Broke on current Ruby

* `Fixnum` was removed in Ruby 3.2. Every LsType, Options and RouterLinkType check
  raised `NameError`. About half the test suite failed.
* `lib/lsa/opaque.rb` was never committed, so the TE LSA could not load at all.
* `IE#method_missing` raised a bare `RuntimeError` for every unknown method. Ruby 3
  `Array#join` probes `to_str`, so printing a Network LSA crashed.
* `sprintf("%4.0d", 0)` prints spaces, not `0`. Ages of 0 vanished from LSDB listings.

### Protocol bugs

* `--area-id` was ignored. `Neighbor#initialize` read `arg[:aread_id]`, so the simulator
  always ran in area 0. The same typo was in `recv_link_state_request` and
  `LinkStateUpdate#ack_lsu`.
* `--hello-interval` never reached the wire. The hello was built with `:helloInt` and
  `:deadInt` keys that `Common#set` silently ignored, and the netmask was hardcoded to
  /24. A DUT using other timers or another mask rejected every hello.
* The simulated router never described the segment shared with the DUT. In
  `bin/ospfv2` the line that added that link was commented out. SPF's two-way check
  (RFC 2328 16.1) then fails at the first hop: the DUT holds all the LSAs but should
  install none of the routes. It now advertises a stub until Full, then a transit link
  to the DR, or a p2p link on a point-to-point network.
* When the simulator was DD master, it declared the exchange done before reading the
  LSA headers in the slave's last DD. Anything on that last page was never requested.
  Small databases fit in one DD, which hid it.
* As DD slave, a retransmitted DD from the master was ignored instead of answered.
  One lost packet stalled the exchange until the master gave up.
* A DD sequence mismatch moved the neighbor to Full instead of ExStart.
* `Exchange#seq_number_mismatch`, `State#method_missing` and `ExStart#adj_ok?` all
  referenced names that do not exist (`neighor`, `Exstart`, `ok`). Any path into them
  raised.
* The inactivity timer set the state to Down without resetting request lists, timers
  or the hello neighbor list.
* `Neighbor#flood` passed an Array where `LinkStateUpdate.new_lsas` needs a Hash.
* The Fletcher checksum loop stopped after 4102 bytes (`n <= MODX`). MODX bounds when
  to reduce modulo 255, not how many bytes to sum. Any LSA over 4 KB got a wrong
  checksum.
* The LSA checksum verifier never ran: `if ! cheksum(...) == [0,0]` is always false.
* Received OSPF packets were never checksum verified (RFC 2328 8.2).
* LSA headers parsed from DD and Ack packets re-encoded with a checksum and length
  recomputed from the 20-byte header. Traces showed wrong values for the DUT's LSAs.
* Link metrics: `new_link` hardcoded 1 and `Link` defaulted to 0, so `bin/ospfv2`
  bringing all links up set every grid metric to 0.
* As a DROther on a broadcast segment, updates and acks should go to AllDRouters.
  They went to AllSPFRouters.
* The simulator re-originated its own router LSA on every intermediate state change.

### Robustness

* `Neighbor#send` overrode `Object#send`. Any code calling `neighbor.send(:foo)` sent a
  packet instead.
* `Thread.abort_on_exception = true` was set process wide at load time. Meanwhile the
  receive and event threads rescued `Exception`, printed it and died silently.
* Timer threads, the receive thread and the console all changed the LSDB with no lock.
* `SendSocket` rescued `EPERM` with a reference to an unbound `e`, then called `exit`
  from inside the library.
* `AdvertisedRouters#has?` sorted the whole set on every call, once per LSA in a DD.
* The option parser defined `-c` twice (network type and console) and `-g` twice.
  `-c p2p` was silently ignored.
* `ostruct`, `observer` and `logger` leave the default gems in Ruby 3.4 to 4.0. All
  three are gone; the gem has no runtime dependency except `irb` for the console.

### Hygiene

* Monkey patches on `Class` (`attr_checked`, `attr_writer_delegate`) and `IPAddr`
  (`+`, `^`, `create`, and an override of the stdlib `netmask`) moved into
  `OSPFv2::Attributes` and `OSPFv2::IP`. `Timer` and `PeriodicTimer` were top level
  constants; they are now under `OSPFv2`.
* Files live under `lib/ospfv2/` with `require_relative`. Before, `require 'ie/id'`
  and `require 'packet/hello'` claimed generic top level paths.
* Every lib file ended with `load "../../../test/..."`, pointing at a directory that no
  longer existed.
* Two pairs of test classes shared names, so tests overwrote each other when the
  suite ran in one process. Two tests had drifted from the code.

## What was added

* **Transport abstraction.** `Transport::RawSocket` for real use, `Transport::Hub` and
  `Loopback` for an in-memory segment. This is what makes the integration tests and the
  demo possible.
* **Topology model.** `Topology` loads YAML or a Ruby DSL, validates with messages that
  name the key, expands `count:` ranges and generates grids.
* **Simulator.** Builds the LSDB from a topology, owns the neighbor, and applies live
  changes (link down, up, flap, refresh, flush) by re-originating and flooding only the
  LSAs they touch.
* **CLI.** `run`, `demo`, `show`, `export` (Graphviz, JSON, YAML), `check`, `init`. The
  original flags still work.
* **Console.** `state`, `links`, `down 3`, `flap`, `lsdb :ios` instead of a bare irb
  binding with `cb $binding`.
* **Web dashboard.** Standard library HTTP server and one HTML page: adjacency ladder,
  topology graph with clickable links, link list, LSDB table, LSA detail, events.
* **Docker.** Runtime and test stages, compose files for a host-network run, a
  two-container lab and an FRRouting lab. CI for Ruby 3.2 to 4.0.

## Tests

| | Before | After |
| --- | --- | --- |
| Tests | 176 (about half failing on Ruby 3.3) | 243 |
| Assertions | 978 | 1209 |

New coverage: Fletcher checksum including LSAs over 4 KB, byte-exact round trips for
every packet type, OSPF packet checksum checks, hello and area validation, the full
adjacency between two simulators (both master/slave orders, a 144-router database paged
over several DDs, a lost DD and a lost LSU, the dead timer), topology parsing and every
error message, simulator link operations and the interface link, the CLI and the HTTP
API.

Verified here: Ruby 3.1, 3.2 and 3.3. In Docker, two containers reached Full over real
raw sockets and multicast, synced 278 LSAs, propagated a link change, and rebuilt the
adjacency after the peer restarted. Not verified here: Ruby 3.4 and 4.0 (CI covers
them), the FRR compose profile, and a hardware router.

## Worth rewriting next

In order of payoff.

1. **`Common#set`, the reflective constructor.** Every IE and LSA is built from a Hash
   whose keys are turned into class names (`:area_id` becomes `AreaId.new`). Unknown
   keys are dropped without a word, which is exactly how `:helloInt` disappeared. A
   small declarative attribute list per class (`attribute :hello_interval, Integer`)
   that rejects unknown keys would remove a class of silent bugs and most of
   `method_missing`.

2. **The DD exchange.** `recv_database_description.rb` is a 150-line nested conditional
   living on `Neighbor`, while the State classes reach into the neighbor through
   `instance_eval`. RFC 2328 10.3 is a table of events by states. Writing it as one,
   with master and slave as separate objects, would make the fixes above structural
   instead of local. The 2-Way state is also missing.

3. **Timers.** One Ruby thread per timer, cancelled with `Thread#kill`. A single
   scheduler in the event loop, with an injectable clock, would make timing tests
   deterministic and fast. Today the integration tests take about a minute because they
   wait on real seconds.

4. **Global state.** `LSDB::Link` keeps a class-level registry and counter, `Summary`
   and `AsExternal` keep class-level address counters, `DatabaseDescription.seqn` and
   `LsAge.aging` are global. Two simulators in one process share them. The Simulator
   resets the link registry on build, which hides it for now. They belong on the LSDB
   or the Simulator.

5. **DD paging cursor.** `DatabaseDescription.new(ls_db:)` advances `ls_db.offset`, a
   cursor stored on the shared database. It should be an iterator owned by the
   adjacency.

6. **Retransmission.** Every unacked LSA is re-flooded every 5 seconds. RFC 2328 keeps a
   retransmission list per neighbor with per-LSA timers. The LSU size limit is a
   constant, not the interface MTU.

7. **Remaining core extensions.** `String#to_camel`, `#hexlify`, `Symbol#to_klass`,
   `Object#to_shex` and `Time.to_ts` are still global. They only add methods now, but a
   refinement or a helper module would keep the gem from leaking into its host.

8. **Features people will ask for.** MD5 and HMAC-SHA authentication (RFC 2328 D, RFC
   5709), TE LSAs in the topology file, NSSA, several neighbors from one process, and
   pcap output of what was sent.
