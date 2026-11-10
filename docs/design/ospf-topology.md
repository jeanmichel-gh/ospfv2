# The LSDB as a topology, for a BGP-LS Producer

Status: draft, for approval.

Two other specs go with this one: routescope
`docs/design/bgp-ls-ospf.md` (the lab, phase 3 of BGP-LS) and bgp4r
`docs/design/bgp-ls-ospf.md` (OSPFv2 as a Producer source).

## The problem

A BGP-LS Producer (RFC 9552) exports an IGP's link-state database as
nodes, links and prefixes. bgp4rd's Producer does this for isis4r: it
reads isisd's `show.topology`, which answers one level's LSDB by node,
with whether SPF reached each node. A node SPF did not reach is
withdrawn (RFC 9552 section 5.9).

ospfd has no such view. `show.database detail` has every LSA's fields,
but a reader would have to rebuild the graph, match transit links to
Network-LSAs, check two-way links, and still not know which routers SPF
reached. That belongs in ospfd, next to the SPF that knows.

## What exists

Read on master at 89d68b1.

- **The API**: JSON lines on `/run/ospfv2/ospfd.sock`, methods in
  `lib/ospfv2/daemon/api.rb:44-78`, answers built in
  `lib/ospfv2/daemon/views.rb`. A new method in `METHODS` appears in
  `api.info` by itself. An `spf` event fires on every run. A change to
  this router's own Type 3, 4, 5 or 7 LSAs runs no SPF
  (`core/instance.rb:803-805`).
- **The LSDB**: one `Core::Lsdb` per area and one AS-wide, keyed by
  type, LS ID and advertising router (`core/lsdb.rb:13-29`). Types 1, 2,
  3, 4, 5 and 7 are stored; opaque LSAs are not.
- **`Core::Lsa#detail`** (`core/lsa.rb:276-292`) gives:
  - Router-LSA: flags B, E, V, and links `{ type: p2p|transit|stub|virtual, id, data, metric }`;
  - Network-LSA: `{ mask, attached }`; the DR's interface address is
    the LS ID, the DR's Router-ID the advertising router;
  - summary, external, NSSA: `{ mask, metric }`, and for 5 and 7
    `external_type`, `forwarding`, `tag`.
- **SPF** (`core/spf.rb`) builds each area's tree in `intra_area`
  (`spf.rb:190-238`), checks two-way links in `each_transit_link`
  (`spf.rb:272-313`), and then drops the tree. It keeps only routes, and
  routers with B or E set (`spf.rb:385-395`). So **nothing records which
  routers and networks an area's SPF reached.**

## The design

### SPF keeps what it reached

`Spf::Table` gains `reached`: for each area, the router IDs and the
network vertices (by the DR's interface address) in that area's tree,
the root included. `intra_area` fills it from `tree` before it returns.
The routes and every other output are unchanged.

`Instance` keeps the last table, as today, so a view can read
`reached` without running SPF.

### A new method: `show.topology`

```text
-> {"id":1,"method":"show.topology","params":{"area":"0.0.0.0"}}
-> {"id":2,"method":"show.topology","params":{"scope":"as"}}
```

`area` (dotted quad or number) or `scope: "as"`, one of the two,
required. Run on the event loop, as every view.

**For an area**, the answer is that area's LSDB by node:

```json
{ "area": "0.0.0.1", "router_id": "10.255.0.2", "run": 12,
  "nodes": [
    { "id": "10.255.0.2", "kind": "router", "reachable": true,
      "abr": true, "asbr": false,
      "neighbors": [
        { "id": "10.255.0.2:10.0.23.1", "type": "transit", "metric": 10 } ],
      "prefixes": [
        { "prefix": "10.255.0.2/32", "metric": 0, "route_type": "intra" },
        { "prefix": "10.0.12.0/30", "metric": 10, "route_type": "inter" } ] },
    { "id": "10.255.0.2:10.0.23.1", "kind": "network", "reachable": true,
      "dr": "10.255.0.2", "address": "10.0.23.1",
      "neighbors": [
        { "id": "10.255.0.2", "metric": 0 },
        { "id": "10.255.0.3", "metric": 0 } ],
      "prefixes": [ { "prefix": "10.0.23.0/24", "metric": 0, "route_type": "intra" } ] } ] }
```

- **A router node** for each Router-LSA in the area.
  - `abr` and `asbr` are its B and E bits.
  - `reachable` is whether the area's last SPF reached it.
  - `neighbors`:
    - one per p2p link, to the neighbor's Router-ID, with
      `address` (this router's interface, the link's Link Data) and,
      when the neighbor's Router-LSA has the link back,
      `remote_address` (the neighbor's Link Data on it);
    - one per transit link, to the network node whose DR interface
      address is the link's ID. A transit link with no Network-LSA for
      it has no neighbor, as SPF has none;
    - virtual links are left out (RFC 9552 5.7: out of its scope).
  - `prefixes`:
    - each stub link, as `intra`;
    - each Type 3 summary-LSA it originated in this area, as `inter`;
    - each Type 7 LSA it originated in this area, as `nssa_1` or
      `nssa_2`.
- **A network node** for each Network-LSA: `id` is `DR:address`, the
  DR's Router-ID and its interface address on the LAN, as RFC 9552
  5.2.1.4 builds an OSPF pseudonode. `neighbors` are the attached
  routers at metric 0, "arcs leading from networks to routers always
  have cost 0" (RFC 2328 section 2.1). Its prefix is the LAN's subnet,
  from the LS ID and the mask.
- Type 4 summary-LSAs are left out (RFC 9552 5.8: out of its scope).

**For `scope: "as"`**, the answer is the AS-scoped LSAs, Type 5, by the
ASBR that sent them:

```json
{ "scope": "as", "router_id": "10.255.0.2", "run": 12,
  "nodes": [
    { "id": "10.255.0.3", "kind": "router", "reachable": true,
      "prefixes": [ { "prefix": "192.0.2.0/24", "metric": 20, "route_type": "external_2",
                      "forwarding": "0.0.0.0", "tag": 0 } ] } ] }
```

`reachable` is true when the ASBR is this router, or SPF has a route to
it in some area (`Table.routers`).

### ospf-cli

Both forms, as every show command:

- Junos: `show ospf topology area 0.0.0.1`, `show ospf topology external`
- IOS: `show ip ospf topology area 0.0.0.1`, `show ip ospf topology external`

A table per node: id, kind, reachable, flags, then its neighbors and
prefixes. `| display json` prints the answer as it is.

### How a reader learns that it changed

isisd's readers wait for its `spf` event. That is not enough here.
ospfd runs no SPF for its own summaries and externals: "SPF never uses
our own summaries and externals: no run for them"
(`core/instance.rb:803-805`). An ABR's Type 3 LSAs, which it sends
after an SPF run, would reach `show.topology` with no event after them.

So a new event kind, `topology`, with `{ area }` or `{ scope: "as" }`:

- after each SPF run, once per area it computed and once for the AS;
- after any change to the LSDB that SPF does not run for: this
  router's own Type 3, 4, 5 and 7 LSAs.

A reader subscribes with `events.subscribe { kinds: ["topology"] }` and
re-reads what the event names. `api.info` lists the kind, as every
event kind.

### What it does not change

- SPF's routes and timing, and the existing events.
- Every existing method and its answer. `show.topology` and the
  `topology` event are additive.

## Pull request

One: ospfv2 `claude/bgp-ls-ospf`. This spec first. Then:

- `Spf::Table#reached`, and `intra_area` filling it;
- `show.topology` in `views.rb` and `METHODS`;
- the `topology` event, in `daemon/events.rb`'s kinds;
- the two CLI forms and their table format;
- the README's method table and `docs/console-panes.md`'s line on ospfd.

## Tests

- SPF: `reached` in a two-area topology, a router cut off in one area,
  a LAN's network vertex, the root itself.
- `show.topology` from a fixture LSDB:
  - p2p links with `address`, and `remote_address` only when the link
    is two-way;
  - a transit link and its network node at metric 0, `id` as `DR:address`;
  - stub links as `intra`, an ABR's Type 3 as `inter`;
  - a router SPF did not reach as `reachable: false`;
  - Type 4 and virtual links left out;
  - `scope: "as"` with an E1 and an E2, forwarding and tag;
  - an `area` this router is not in, a missing parameter, both given:
    errors.
- The `topology` event: after an SPF run, per area; after this router
  re-originates a Type 3 with no SPF run.
- The CLI's two forms parse and print.
- The full unit suite: `bundle exec rake test:unit`.

## Gate

routescope's phase 3 lab: o2's `show.topology` for areas 0 and 1 and
the AS, checked against `show.database detail` by hand once, then by
routescope's comparison through bgp4rd.

## Open questions

- Should `reached` also be in `show.spf`? Not needed by the Producer.
  Left out unless asked.
