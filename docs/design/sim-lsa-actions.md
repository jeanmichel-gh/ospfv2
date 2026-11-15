# The simulator acts on one LSA, toggles routes, and streams its events

Status: proposed 2026-11-15. Not approved. Not started.

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
(`Simulator#reoriginate` calls `force_refresh`). I do not know whether
that is on purpose, for a test tool that wants to push a router, or an
oversight. The design below keeps that behaviour and reports it.

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
age, checksum. A refresh also says `"within_min_ls_interval": true` when
the last origination of that LSA was under 5 s ago, so a test can see it
pushed the rule.

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
sequence number.

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

### 3. Streaming events

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
- `Sim::EVENTS` reads `/api/events/stream` when the simulator's API says
  it has it, and polls as today when not. How it asks is question 3.

## Tests

In ospfv2:

- `Simulator`, with the in-memory segment the integration tests use:
  - one LSA refreshed: only it is flooded, with sequence + 1;
  - one LSA flushed: flooded at MaxAge with the same sequence number;
    then refreshed: back with a higher one;
  - an LSA of the router under test: refused;
  - the simulator's own router LSA: refresh allowed, flush refused;
  - an external withdrawn then advertised; a summary the same;
  - `within_min_ls_interval` set on a second refresh inside 5 s.
- `Web::Server#call`: each new route, its 400, 404 and 409, and the
  `X-OSPFv2` header refusal (403) for each POST.
- The stream: replay after `since`, a new event arriving, a keepalive
  with a short interval set in the test, and the cap.
- One FRR interop check, where the interop suite runs FRR: an external
  withdrawn from the simulator leaves FRR's database and its route
  table.

In routescope, in its own pull request: the driver's action table, a
scenario validation test, and the stream read against a fake.

## Out of scope

- Enforcing MinLSInterval in the simulator. It keeps re-originating at
  once and reports when it did so inside 5 s.
- Changing an external's metric or type at runtime. It is the same
  mechanism and can follow.
- NSSA type 7 LSAs. The simulator has no NSSA (`REVIEW.md` item 8).
- The simulator's protocol stack debts in `REVIEW.md`. This works with
  the stack as it is.

## Questions for the owner

1. **MinLSInterval.** Keep re-originating at once and report it, as
   proposed, or wait out the 5 s as RFC 2328 12.4 asks a real router to?
2. **New prefixes.** Is toggling the topology's own externals and
   summaries enough, or should `routes.advertise` also take a prefix that
   is not in the file, with its metric and type?
3. **How routescope learns the stream exists.** The simulator has no
   `api.info`. Add a small `GET /api/info` with its version and routes,
   as ospfd's `api.info` gives, or let routescope try the stream and fall
   back on a 404?

## Work, once approved

1. `Simulator#lsa_refresh`, `#lsa_flush`, with the 14.1 rule and tests.
2. `Simulator#routes_withdraw`, `#routes_advertise`, with tests.
3. The four POST routes, and their tests.
4. Event `data` and full timestamps; `GET /api/events/stream`, with tests.
5. The FRR interop check.
6. `docs/user-guide.md` and CLAUDE.md's table move the three rows to
   done.
7. Then the routescope pull request.
