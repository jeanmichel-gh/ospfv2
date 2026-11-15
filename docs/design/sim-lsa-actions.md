# The simulator acts on one LSA, toggles routes, and streams its events

Status: proposed 2026-11-15. The owner answered its three questions the
same day (below). Not started.

## The problem

routescope's simulator pane drives `ospfv2 sim` through its HTTP API,
`lib/ospfv2/web/server.rb`. Measured on master 005fdba, the API can:

- take a link up or down, toggle it, flap it, set its metric;
- refresh every LSA the simulator owns, or flush them all
  (`Simulator#refresh_all`, `#flush_all`);
- turn aging on or off, start or stop the neighbor;
- answer `GET /api/events?since=N` with the events after `N`.

`docs/console-panes.md` asks for three more things, and CLAUDE.md, "What
routescope asked of ospfv2", lists them as not started:

1. Refresh or flush **one** LSA.
2. Add and withdraw **externals and summaries** at runtime. Today they
   come only from the topology file.
3. A **streaming** event endpoint. routescope polls `/api/events` every
   0.5 s from inside the container (routescope `drivers.rb`,
   `Sim::EVENTS`) and reshapes each event into ospfd's stream format.

Without 1 and 2 a test can only move the whole simulated area at once.
"Withdraw one external and time how long FRR takes to drop the route"
cannot be written. Without 3 every event is up to half a second late,
and an event carries only text, so the console cannot follow one LSA
instance from the simulator to each router.

## What the RFC says, read in `specs/rfc/rfc2328.txt`

- **Section 14.1, premature aging.** An LSA is flushed by setting its age
  to MaxAge, leaving its sequence number alone, and flooding it again. It
  names withdrawing an external as a use: "the router can flush its
  AS-external-LSA from the routing domain via premature aging. This
  procedure is preferable to the alternative, which is to originate a
  new LSA for the destination specifying a metric of LSInfinity."
- **Same section:** "A router may only prematurely age its own
  self-originated LSAs."
- **Section 12.4:** "two instances of the same LSA may not be originated
  within the time period MinLSInterval." Appendix B sets MinLSInterval to
  5 s and MinLSArrival to 1 s. A router discards a new instance that
  arrives within MinLSArrival of the last one.

The simulator plays every router of the simulated area, so "its own"
means every LSA whose advertising router it proxies
(`LinkStateDatabase#proxied?`). The router under test's LSAs are in the
simulator's database too, and it must not flush those.

Today `refresh_all` re-originates at once, with no MinLSInterval wait
(`Simulator#reoriginate` calls `force_refresh`), and so does every other
action. The owner's answer: do not ignore the 5 s rule. ospfd already
keeps it (`core/instance.rb`, `originate`, around line 416), so the
simulator follows ospfd's way, below.

## The design

### 1. One LSA: refresh and flush

An LSA is named by the key the API already uses in `GET /api/lsa`:
`type`, `id` (Link State ID) and `advr` (advertising router). `type` is
one of the names `lsdb_rows` gives: `router`, `network`, `summary`,
`asbr_summary`, `as_external`, and the opaque types.

```
POST /api/lsa/refresh  {"type":"router","id":"1.1.2.3","advr":"1.1.2.3"}
POST /api/lsa/flush    {"type":"as_external","id":"203.0.113.0","advr":"1.1.4.4"}
```

Both answer the LSA's row, as `GET /api/lsdb` gives it: sequence number,
age, checksum. When MinLSInterval holds the new instance back, the answer
says so instead: `"deferred_ms": 3120`, the time until it goes out.

Rules:

- **Not ours: 409.** An LSA whose advertising router the simulator does
  not proxy is refused, "not originated by the simulator (RFC 2328
  14.1)". The server already maps `PermissionError` to 409.
- **Unknown: 404**, as `GET /api/lsa` answers.
- **Flush keeps the sequence number**, as 14.1 says, and remembers it the
  way `flush_all` does (`@flushed_seq`).
- **Refreshing a flushed LSA brings it back** with a sequence number above
  the flushed copy, as `restore` does for all of them. It is rebuilt from
  the topology and the current link states, so a flushed router LSA comes
  back with today's metrics.
- **The simulator's own router LSA** (the one with the link to the router
  under test) can be refreshed. Flushing it is refused: it would cut the
  area off from the router under test, and `neighbor.stop` already does
  that honestly.

Each action writes one event, kind `lsdb`, naming the LSA and its new
sequence number, when the instance goes out.

### MinLSInterval, for every origination

Every LSA the simulator originates waits out MinLSInterval (5 s, RFC 2328
12.4 and Appendix B) after its last instance. This covers the new actions
and the old ones: link up and down, metric, flap, `refresh_all`,
`restore`. It is ospfd's way:

- The simulator remembers when it last sent each LSA, by its key.
- A change inside the 5 s starts one timer for that LSA. More changes
  meanwhile join it. When the timer fires, the LSA goes out once, with
  the contents it has then.
- A flush is an instance too. An advertise or refresh right after a
  flush waits, as ospfd's `flush` says: "the next origination waits
  MinLSInterval, or routers two hops away drop it (13 step 5a)".
- A held LSA shows in `GET /api/lsdb` with `"deferred_ms"`, and in
  `/api/state`'s counts as `deferred`.

What this changes for the old actions:

- **A flap faster than 5 s is folded.** A link down and up again inside
  5 s may send nothing, because when the timer fires the router LSA is
  the same as before. The router under test never sees the flap. The
  flap's `interval` keeps its range (0.5 s up), so nothing a caller sends
  is refused, and the answer and the event say when an instance was held.
  The pane's flap control suggests 5 s or more.
- **Two metric changes inside 5 s** send one instance, with the second
  metric.

The interval is 5 s. Tests may build a Simulator with a shorter one
(`min_ls_interval:`, a constructor option, not a topology setting), so
the suite does not sleep. A lab file cannot change it.

### 2. Externals and summaries: withdraw and advertise

This follows isis4r's simulator, which has `prefixes.withdraw` and
`prefixes.advertise` for a router and a prefix defined in its topology.
A prefix is named by the router that originates it and the prefix, as in
the topology file.

```
POST /api/routes/withdraw   {"router":"r4c4","prefix":"203.0.113.0/24"}
POST /api/routes/advertise  {"router":"r4c4","prefix":"203.0.113.0/24"}
```

- The prefix is looked up in that router's `externals`, then its
  `summaries`. The answer says which it was: `{"kind":"as_external", ...}`.
- **Withdraw** is a premature aging of that one LSA (14.1), not
  LSInfinity.
- **Advertise** of a withdrawn one originates it again, sequence number
  above the flushed copy. Advertise of one that is already advertised
  does nothing and says so.
- A prefix not in the topology is 404, with the router's prefixes listed
  as `find_link` lists links.

This first version toggles only what the topology defines. A scenario
then reads the same topology file to know what can move. Adding a prefix
that is not in the file is question 2 below.

### 3. `GET /api/info`

The owner's answer to question 3: the simulator says what it has, as
ospfd's `api.info` does.

```
GET /api/info
{"daemon":"ospfv2-sim","version":"1.0.0","api":1,
 "routes":["GET /api/state", "...", "POST /api/lsa/refresh", "GET /api/events/stream"]}
```

- `version` is the gem's, `OSPFv2::VERSION`.
- `api` is a number raised when a route changes in an incompatible way,
  as ospfd's `Api::VERSION`.
- `routes` is every route the server answers, generated from the same
  table `call` routes on, so the list cannot drift from the code.
- No header needed: it is a GET, and it says nothing a page of the lab
  cannot already read.

routescope's contract (its `docs/design/api-contract.md`) asks
`api.info` of each daemon and greys what an older one lacks. The Sim
driver does the same with this: a simulator without `/api/info` (a 404)
is an older one, polled as today, with the new actions greyed.

### 4. Streaming events

```
GET /api/events/stream?since=N
```

A long-lived response, one JSON object per line, in the line shapes of
ospfd's `events.subscribe` (`daemon/api.rb`), so routescope reads both
with one parser:

```
{"result":{"seq":131,"replayed":11}}
{"event":{"seq":121,"time":"2026-11-15T03:18:30.512Z","level":"info","kind":"lsdb","message":"...","data":{...}}}
{"keepalive":"2026-11-15T03:18:45.004Z","seq":131}
```

- Events after `since` come first, then new ones as they happen.
- A keepalive line every 15 s, as ospfd's `KEEPALIVE`.
- `time` becomes a full UTC timestamp with milliseconds. Today it is
  `HH:MM:SS`, and routescope guesses the date.
- `data` carries what the text says, as fields. For an LSA action:
  `{"lsas":[{"type":"router","id":"1.1.2.3","advr":"1.1.2.3","seq":"0x80000005"}]}`.
  That is what the console needs to follow one LSA instance.
- The server already runs one thread per connection, so a stream holds
  one thread while it lasts. It ends when the client goes. At most 8
  streams at once; the ninth gets 503.
- `GET /api/events` stays as it is. Its events gain the same `data`
  field. Nothing is removed, so an older routescope keeps working.

### What routescope does with it, in a routescope pull request after

- `Drivers::Sim::ACTIONS` gains `lsa.refresh`, `lsa.flush`,
  `routes.withdraw` and `routes.advertise`. The scenario `sim:` step
  takes its actions from that table, so scenarios get them as soon as
  the driver has them:

  ```yaml
  - sim: routes.withdraw
    router: r4c4
    prefix: 203.0.113.0/24
  - expect: { route: { node: frr, prefix: 203.0.113.0/24, present: false } }
    within: 15
    measure: withdrawn
  ```
- The simulator pane gains Refresh and Flush on a selected LSA row, and
  Withdraw and Advertise on a router's prefixes.
- `Sim::EVENTS` reads `/api/events/stream` when `/api/info` lists it,
  and polls as today when not.
- The driver asks `/api/info` and greys the actions an older simulator
  lacks, as the contract does for the daemons.

## Tests

In ospfv2:

- `Simulator`, with the in-memory segment the integration tests use:
  - one LSA refreshed: only it is flooded, with sequence + 1;
  - one LSA flushed: flooded at MaxAge with the same sequence number;
    then refreshed: back with a higher one;
  - an LSA of the router under test: refused;
  - the simulator's own router LSA: refresh allowed, flush refused;
  - an external withdrawn then advertised; a summary the same;
  - MinLSInterval, with a short interval set in the test: a second
    refresh inside it is held and goes out once when the timer fires;
    two metric changes inside it send one instance with the second
    metric; an advertise right after a withdraw waits; a refresh after
    the interval goes out at once.
- `Web::Server#call`: each new route, its 400, 404 and 409, and the
  `X-OSPFv2` header refusal (403) for each POST.
- `GET /api/info`: every route `call` answers is in `routes`, and no
  listed route answers 404.
- The stream: replay after `since`, a new event arriving, a keepalive
  with a short interval set in the test, and the cap.
- One FRR interop check, where the interop suite runs FRR: an external
  withdrawn from the simulator leaves FRR's database and its route
  table.

In routescope, in its own pull request: the driver's action table, a
scenario validation test, and the stream read against a fake.

## Out of scope

- Changing an external's metric or type at runtime. It is the same
  mechanism and can follow.
- NSSA type 7 LSAs. The simulator has no NSSA (`REVIEW.md` item 8).
- The simulator's protocol stack debts in `REVIEW.md`. This works with
  the stack as it is.

## The owner's answers, 2026-11-15

1. **MinLSInterval:** "don't ignore the 5 s rule". Every origination
   waits it out, as ospfd does (section 1, "MinLSInterval").
2. **New prefixes:** "no new prefixes". Only the topology's own
   externals and summaries are withdrawn and advertised.
3. **How routescope learns what the simulator has:** "an api info is
   warranted". `GET /api/info` (section 3).

## Work, once approved

1. MinLSInterval in `Simulator#reoriginate` and `#flush_all`, for every
   action, with its tests; the existing tests built with a short
   interval.
2. `Simulator#lsa_refresh`, `#lsa_flush`, with the 14.1 rule and tests.
3. `Simulator#routes_withdraw`, `#routes_advertise`, with tests.
4. The four POST routes and `GET /api/info`, and their tests.
5. Event `data` and full timestamps; `GET /api/events/stream`, with tests.
6. The FRR interop check.
7. `docs/user-guide.md` and CLAUDE.md's table move the three rows to
   done.
8. Then the routescope pull request.
