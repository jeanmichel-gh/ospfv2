# Segment routing in ospfd

Status: approved by the owner 2026-11-25, merged in #65. Not built.
The open questions at the end keep the answers this document gives
until the owner changes them.

This is P7 in routescope's `docs/protocol-coverage.md`: SR in OSPF. It
comes after IS-IS (P1) because fewer SP cores run OSPF, and it reuses
P1's design (isis `docs/design/sr-mpls.md`). bgp4r's L3VPN specs say an
OSPF core has no labels "until SR in OSPF (P7)", so it uses GRE today.
P9, flex-algo in OSPF (RFC 9350, RFC 9492), comes after this and needs
the Router Information and extended link LSAs built here.

The work is in build order:

1. Opaque LSAs (RFC 5250).
2. The Router Information LSA (RFC 7770), with SR's TLVs.
3. The extended prefix and extended link LSAs (RFC 7684).
4. SR-MPLS (RFC 8665): prefix-SIDs, adj-SIDs, label routes in the
   kernel.
5. The simulator: SR LSAs from a topology file.
6. TI-LFA: out of this spec, with the reason.

## The terms, in short

From RFC 8402 section 3 and RFC 8665. A reminder, not a definition.

- **Opaque LSA**: LS type 9 (link scope), 10 (area scope) or 11 (AS
  scope). The link state ID is an 8-bit opaque type and a 24-bit opaque
  ID (RFC 5250 section 3).
- **O bit**: 0x40 in the Options field. A neighbor is opaque capable if
  and only if it sets O in its DD packets (RFC 5250 section 3.1).
- **RI LSA**: opaque type 4, the Router Information LSA (RFC 7770
  section 2.1). SR puts its capabilities there.
- **Extended prefix LSA**: opaque type 7. **Extended link LSA**: opaque
  type 8 (RFC 7684 sections 2 and 3). SR puts its SIDs there.
- **SRGB**, **SRLB**, **Prefix-SID**, **Node-SID**, **Adj-SID**, **PHP**:
  as in isis `docs/design/sr-mpls.md`, "The terms, in short".

## What exists

Read at ospfv2 `cc14800`, 2026-11-25.

### The router core does not take opaque LSAs

- `core/neighbor.rb:15-18`: `SUPPORTED_TYPES = [1, 2, 3, 4, 5, 7]`. The
  comment says: "Anything else in a DD is a SeqNumberMismatch (RFC 2328
  10.6). We do not set the O bit, so compliant neighbors do not offer
  opaque LSAs."
- `core/neighbor.rb:321-323`: `accept_dd` calls
  `seq_number_mismatch("unsupported LSA type #{h.type}")` for any other
  type in a DD. That follows RFC 2328 section 10.6: "If the LS type is
  unknown (e.g., not one of the LS types 1-5 defined by this
  specification) ... generate the neighbor event SeqNumberMismatch". So
  a neighbor that offers a type 10 in a DD, though we never set O,
  restarts the exchange for ever.
- `core/area.rb:59`: `options` for Hellos and DDs is 0x08 (N) in an
  NSSA, 0x02 (E) in a normal area, else 0. Never 0x40.
- `core/neighbor.rb:285, 293`: the neighbor's DD options are kept in
  `@options`, and a change is a SeqNumberMismatch (`:307`). So the
  neighbor's O bit is already stored; nothing reads it.
- `core/instance.rb:50-51`: `AS_SCOPE = [5]`, `AREA_SCOPE = [1, 2, 3,
  4, 7]`. `lsdb_for` (`:230`) gives nil for any other type, and
  `receive_update` (`:328-338`) drops it with "unsupported type N". That
  is RFC 2328 section 13 step (2): "If the LS type is unknown, discard
  the LSA".
- There is no link-scope database. An area has one `Lsdb`
  (`core/lsdb.rb`), and the instance one for AS scope. An `Interface`
  has none.
- `core/lsa.rb:46-48` already names types 9 to 11 (`opaque_link`,
  `opaque_area`, `opaque_as`). The core keeps an LSA as its bytes, so
  storing and flooding an opaque LSA needs no body codec.
- `core/lsa.rb:171`: `Lsa.build` builds any type from a body, so
  originating an opaque LSA needs only the body.
- `daemon/views.rb:60`: `show.database` gives `scope: area ? :area :
  :as`. A link-scope row needs a third value and its interface.

### Forwarding has no MPLS

`fib/netlink.rb` writes IPv4 routes: `RTA_DST`, `RTA_OIF`,
`RTA_GATEWAY`, `RTA_PRIORITY`, `RTA_MULTIPATH`, `RTA_TABLE`. No
`AF_MPLS`, no `RTA_VIA`, `RTA_NEWDST` or encap. The FIB `Manager`
diffs IP routes only.

### The simulator has a TE codec only

- `lsa/lsa_factory.rb:43-48`: from bytes, types 9 to 11 with opaque
  type 1 become `TrafficEngineering` (RFC 3630). Any other opaque type
  returns nil, silently. From a Hash, opaque type 1 only; anything else
  raises.
- `lsa/tlv/tlv_factory.rb`: top-level TLVs 1 (Router Address) and 2
  (Link); sub-TLVs 1 to 9 of RFC 3630. An unknown type raises.
- `lsa/opaque.rb` is a stub; the opaque header lives in `Lsa`.
- `neighbor/interface.rb:475`: the simulator's Hellos carry options 2.
  The DD takes the Hello's options (`neighbor/neighbor.rb:236`). So the
  simulator never sets O either.
- `topology.rb` has no TE and no SR keys. routescope's coverage table
  says the same: "Topology files cannot emit TE LSAs".
- `dissect.rb:52, 355` already names the opaque types and splits the
  link state ID into opaque type and ID.

### The conventions ospfv2 lacks

routescope `docs/design/protocol-conventions.md`, "The work", item 3,
lists ospfv2's gaps: no `validation.rb` (checks are inline, with
`Interface#drop(kind, reason)`), no receive policy, no
`OSPFv2::Fault` catalog (byte edits in tests), no `/api/fault` on the
simulator, a codec that drops an unknown LSA instead of keeping it, and
no fault matrix against FRR. isis closed the same gaps for SR first, as
TI-LFA's step 0 (isis #97, #100 to #103). This spec does the same for
OSPF's SR: step 0 below.

### FRR, measured

On ospflab, 2026-11-25, from the images on the VM:

- `quay.io/frrouting/frr:10.2.1`, the version ospfv2's labs and CI pin
  (`.github/workflows/ci.yml`, `test/lab/pull.sh`). `ospfd --version`
  prints `10.2.1_git`.
- `quay.io/frrouting/frr:10.7.1`, also on the VM. `10.7.1_git`.

`strings /usr/lib/frr/ospfd` in both has `capability opaque`,
`router-info area`, `router-info as`, `segment-routing global-block
(16-1048575) (16-1048575) [local-block ...]`, `segment-routing prefix
A.B.C.D/M [index (0-65535)|no-php-flag|explicit-null]`, `fast-reroute
ti-lfa [node-protection]`, and `show ip ospf database segment-routing
[adv-router A.B.C.D|self-originate] [json]`. 10.7.1 adds a message
that the RI LSA "uses incorrect flooding scope (should be Area scope,
not AS scope)".

Neither has flex-algo in ospfd: `strings | grep -ci flex.algo` gives 0
on 10.7.1. That matters for P9, below.

## The design

### Step 0: conventions first

Before any SR code, as isis did:

- **`validation.rb`** in `core/`: named findings, each with its RFC
  section and the action the RFC asks for. The SR findings come first
  (the table in step 4). The inline drops in `receive_update` and
  `accept_dd` that this spec touches become findings too. The policy is
  `:rfc` by default, with `:strict` and `:lenient`, as routescope's
  open question 1 settles their names. `Interface#drop` counts by
  finding.
- **`OSPFv2::Fault`**: a catalog with `name`, `description`, `expect`,
  `rfc` and `build`, starting with the opaque and SR entries of this
  spec: a type 11 into a stub area, a type 9 flooded to another
  interface, an RI LSA with two SR-Algorithm TLVs, a SID/Label Range of
  size 0, a Prefix-SID with V set and L clear, a sub-TLV whose length
  overruns its TLV, and others as each step needs them. A test checks
  that the catalog and `validation.rb` agree.
- **`POST /api/fault`** on the simulator, with the `X-OSPFv2` header it
  already asks for. The rest of the simulator's codec work is step 5.

RFC 2328's own entries (header, Hello, DD, LSU) stay
protocol-conventions' item, not this spec's.

#### As built, step 0

- **`core/validation.rb`**, on isis's: a `Rule` has a name, a group, the
  RFC text, a description and one action per policy. A `Finding` has
  the rule's name, group and text, a subject and a detail. Validation
  decides nothing; the caller acts. Each clause was checked against
  the RFC text: RFC 2328 sections 10.6, 13 and 15, RFC 3101 section 2.3,
  RFC 5250 section 3.1, RFC 7684 section 5, and RFC 8665 sections 3.1,
  3.2, 3.3, 5 and 9.
- **Three groups.** `rfc2328` holds the drops of `receive_update` and
  `accept_dd` that this spec touches: an external in a stub area or over
  a virtual link, a type 7 outside an NSSA, an unknown type, and the
  same three in a DD. `opaque` holds a type 11 in a stub area. `sr`
  holds two SR-Algorithm TLVs, a SID/Label Range or SRLB of size 0, a
  Prefix-SID with V and L unequal, and a TLV past its end.
- **The policy.** `Instance.new(receive_policy:)`, `:rfc` by default,
  checked by `Validation.policy`. Every rule ospfd acts on today takes
  the same action under each policy, since nothing can be stored where
  an area has no database. So it changes nothing yet, and it has no
  configuration statement; step 4 adds one, when SR's rules act.
- **Counted by finding.** `Interface#drop(kind, reason, finding:)`
  counts `drop_KIND` as before and `finding_NAME` beside it, and the
  `drop` event gains `finding`. A DD's SeqNumberMismatch counts its
  finding too. `show.statistics` gives both, per interface.
- **A type 11 in a stub area** is the one opaque rule ospfd acts on now:
  `receive_update` drops it as `opaque_as_in_stub`, not as an unknown
  type. Types 9 to 11 elsewhere stay unknown types until step 1.
- **The body walk.** `Validation.opaque(opaque_type, body, subject)`
  reads RI, extended prefix and extended link bodies and returns the
  findings. It never raises: an overrun is a finding, and the walk
  stops. Steps 2 and 3 call it from their codecs.
- **A TLV past its end drops the LSA.** The draft said such an LSA is
  "still stored and flooded", from RFC 5250 section 3. RFC 7684
  section 5 says otherwise for the extended LSAs: "Malformed LSAs MUST
  NOT be stored in the Link State Database (LSDB), acknowledged, or
  reflooded". RFC 5250 asks a router to store a *valid* opaque LSA.
  So `tlv_overrun`'s action is `:drop_lsa`. Step 1 acts on it.
- **`OSPFv2::Fault`** (`lib/ospfv2/fault.rb`): six entries, one per
  `opaque` and `sr` rule. An entry is `[name, finding, description,
  build]`. Its `expect` and `rfc` come from the rule, so they cannot
  drift. `Fault.lsa` gives a `Core::Lsa` with a good checksum, from a
  context (router ID, index, SRGB, SRLB, sequence number).
- **Not in the catalog: a type 9 flooded to another interface.** A
  receiver cannot tell it from a type 9 for its own link, so it has no
  finding. Step 1's core tests check that ospfd keeps a type 9 on its
  interface.
- **The tests.** Every `opaque` and `sr` rule has one entry and every
  entry one rule. Each SR entry makes its finding, and no other,
  through `Validation.opaque`. The stub entry makes its finding through
  two ospfd instances Full in a stub area, and fails without the
  change.
- **The simulator.** `POST /api/fault` with `case` and `router` (the
  simulator's router ID if left out) floods the entry's octets as they
  are, a newer instance each time. It is not in the simulator's
  database. `POST /api/fault/clear` flushes them at MaxAge, and `GET
  /api/faults` gives the catalog and what was sent. Each is an `lsdb`
  event, so no new event kind. Both POSTs need the `X-OSPFv2` header,
  as every POST does.

### Step 1: opaque LSAs (RFC 5250)

What changes in `core/`:

- **The O bit.** ospfd sets 0x40 in its DD options when opaque is on
  (RFC 5250 section 3.1: a neighbor is opaque capable "if and only if
  it sets the O-bit in the Options field of its Database Description
  packets"). Not in Hellos: "the O-bit SHOULD NOT be set and MUST be
  ignored when received in packets other than Database Description
  packets". So `Interface#options` and the DD's options part ways: a
  new `dd_options`. The Hello check of E and N (`core/interface.rb:339`)
  stays, and ignores O.
- **When opaque is on.** On whenever SR is configured, and by its own
  statement (open question 1). Off, the DD options and every packet
  stay byte for byte as today.
- **Types 9 to 11 in a DD.** With opaque on, `SUPPORTED_TYPES` gains 9,
  10 and 11. A type 11 from a neighbor in a stub area or NSSA is a
  SeqNumberMismatch, as a type 5 is (RFC 5250 section 3: "the LSA is
  rejected"). With opaque off, the list stays as today.
- **Scopes.** `AREA_SCOPE` gains 10, `AS_SCOPE` gains 11. Type 9 gets a
  link-scope database per interface. RFC 5250 section 3.1 asks that a
  type 9 "MUST be discarded and not acknowledged" when the interface it
  came in on is not the target interface, and that a type 10's area be
  tracked. One `Lsdb` per interface does both.
- **The summary list.** RFC 5250 section 3.2 changes ExStart,
  NegotiationDone: the list holds the area's types 1 to 4, 9 for this
  interface, 10, then 5 and 11 from the AS database; 5 and 11 left out
  for a virtual neighbor and in a stub area or NSSA.
- **Flooding.** An opaque LSA goes only onto the retransmission lists
  of neighbors that set O (RFC 5250 section 3.1: "MUST be placed on the
  link-state retransmission lists of opaque-capable neighbors and MUST
  NOT be placed on" the others). A multicast update may still reach a
  non-capable neighbor, which drops it; that is the RFC's own text.
- **A type 11's originator.** RFC 5250 section 5: a router that
  originates type 11 advertises itself as an ASBR; a receiver uses a
  type 11 only while it has a route to that ASBR. SR in this spec
  originates no type 11 except for externals (step 4), and only an ASBR
  originates those. Readers of type 11 follow section 5 (2).
- **Unknown opaque types** are stored and flooded as bytes, as any
  opaque LSA. Only the ones a reader asks for are decoded.
- **Our own opaque LSAs** go through `originate` as the other types
  do: one spec per (type, opaque type, opaque ID), refreshed every
  LSRefreshTime, flushed at shutdown.
- **API.** `show.database` rows for types 9 to 11: `scope` is `link`,
  `area` or `as`; a link row has `interface`; opaque rows add
  `opaque_type` and `opaque_id`. Additive. `show.neighbors` gains
  `opaque: true|false`, from the neighbor's DD O bit.

Gate: with FRR 10.2.1 beside ospfd, `capability opaque` and
`router-info area` on FRR, ospfd reaches Full, its `show.database` lists
FRR's type 10 RI LSA, and FRR's `show ip ospf database opaque-area`
lists one ospfd originated. Before this step, the same pair loops in
ExStart if FRR offers a type 10 in its DD; whether it does to a
neighbor without O is measured, not assumed, and the test records it.

#### As built, step 1

- **The statement** is `set protocols ospf opaque`, ospfd's own, as
  FRR's `capability opaque` (open question 1's draft answer: by a
  statement too). Junos has none. Step 4 turns opaque on with SR.
- **Turning it on or off** (`Instance#opaque=`) takes every adjacency
  down, so each forms again with the new DD options. Off, the opaque
  LSAs held are dropped, and ours flushed first.
- **The O bit** is in `Interface#dd_options`, not `options`, so Hellos
  stay as they were. `Neighbor#opaque?` reads the neighbor's DD
  options, and is false while opaque is off here.
- **Scopes.** `AREA_SCOPE` gains 10 and `AS_SCOPE` 11. `lsdb_for`
  gives nil for 9 to 11 while opaque is off, so they stay unknown types
  (RFC 2328 section 13 (2)). Each `Interface` has a `link_lsdb` for its
  type 9s; it is emptied when the interface goes down. The helpers that
  took an area (`scope_interfaces`, `scope_key`, `flood`, `flush`,
  `exchanging?`, `drop_old_retransmits`, `sweep_db`) take the interface
  too, for a type 9.
- **The summary list** follows RFC 5250 section 3.2: the interface's
  type 9s join the area's and the AS's databases, and opaque LSAs are
  left out for a neighbor that did not set O.
- **Flooding** skips a neighbor without O for an opaque LSA, so it is on
  no retransmission list of one (RFC 5250 section 3.1).
- **A type 11 offered in a DD in a stub area** is a SeqNumberMismatch,
  with the new finding `dd_opaque_as_in_stub` (RFC 5250 section 3).
  It is in the `rfc2328` group, the receive path's checks: a DD
  carries headers, not an LSA, so it has no catalog entry. A type 11
  received over a virtual link is dropped as `as_external_over_virtual_link`,
  as a type 5 is: RFC 5250 section 3.2 leaves both out of a virtual
  neighbor's summary.
- **Our own opaque LSAs** come from `Instance#opaque_lsas=`, as
  `externals=`: types 10 and 11, by opaque type and ID, new and changed
  ones originated, the rest flushed. They go through `originate`,
  refresh every LSRefreshTime and flush at shutdown. Their options
  carry O as well. No statement originates one: step 2 does, with the
  RI LSA. Type 9 is not originated; nothing here needs one.
- **SPF** does not run for an opaque LSA, and the externals SPF reads
  are the type 5s only. RFC 5250 section 5 (a type 11 used only while
  its originator is reachable) waits for the first reader of a type 11.
- **`show.database`** rows for 9 to 11 gain `opaque_type` and
  `opaque_id`; a type 9 row has `scope` `link` and `interface`.
  `show.neighbors` gains `opaque`. `show.overview`'s `external_lsas`
  counts type 5s only, as its name says.
- **ospf-cli** prints opaque rows with their type number (9, 10, 11).
  Junos's and IOS's own names for them are left for a later change,
  checked against their documentation.
- **The tests**, on the fake clock (`test/unit/core/opaque_test.rb`):
  the O bit in DDs and not in Hellos; DDs as before with opaque off; a
  type 10 flooded and learned by the database exchange; none to a
  neighbor without O; a type 11 kept out of a stub area; a type 9 kept
  on its interface; a DD's type 11 in a stub area; a withdrawn LSA
  flushed, a changed one a new instance; opaque turned off; no SPF run.
  The O-bit filter and the SPF guard were each taken out, and their
  tests failed.
- **Interop with FRR**, in network namespaces (`frr_interop_test.rb`),
  run in CI's `interop-frr` job on Ubuntu 26.04's FRR, 10.5.1:
  - both opaque: Full, and each lists the other's type 10;
  - FRR opaque (`capability opaque`, `router-info area`) and ospfd
    not: Full, with no SeqNumberMismatch. Measured: FRR sets O in its
    DDs and offers no opaque LSA to a neighbor that does not set O.
    The ExStart loop the draft feared does not happen with this FRR.

  On ospflab, AppArmor's `ospfd` profile stops FRR in a namespace, so
  they were not run there. The gate against 10.2.1 in a container lab
  waits for step 8's labs.

### Step 2: Router Information (RFC 7770)

- One RI LSA, type 10, opaque type 4, opaque ID 0, per area (RFC 7770
  section 2.1). Area scope, since RFC 8665 section 3.1 says "For the
  purpose of SR-Algorithm TLV advertisement, area-scoped flooding is
  REQUIRED", and the same for the Range and SRLB TLVs (3.2, 3.3).
- **TLVs** (RFC 7770 section 2.3 format: 2-octet type, 2-octet length,
  value padded to 4 octets, padding not in the length):
  - 1, Router Informational Capabilities: "If included, it MUST be the
    first TLV in the first instance" (2.4). 4 octets, no bits set:
    ospfd has none of graceful restart, stub router or TE.
  - 8, SR-Algorithm (RFC 8665 section 3.1): `[0]`. "If the SR-Algorithm
    TLV is advertised, Algorithm 0 MUST be included."
  - 9, SID/Label Range (3.2): one per SRGB range, in configured order.
    A 3-octet size, a reserved octet, and one SID/Label sub-TLV (type
    1, length 3, a label).
  - 14, SRLB (3.3): the same shape.
- **Reading.** For each router, the first SR-Algorithm TLV; with
  several RI LSAs, the area-scoped one, then the lowest instance ID
  (3.1). The SRGB is the Range TLVs in order (3.2: "The receiving
  router MUST adhere to the order"). A Range TLV with more than one
  SID/Label sub-TLV is ignored (3.2). A router without SR-Algorithm "is
  considered as not being Segment Routing capable" (3.1).
- **Unknown TLVs** are kept as octets and ignored (2.3: "Unrecognized
  types are ignored"). This is what keeps P9 open: RFC 9350 section 5.2
  adds the Flexible Algorithm Definition TLV, type 16, to the same LSA.
  The codec is a registry of TLV types, not a `case`.
- RFC 8476's Node MSD TLV is not sent. FRR's isisd sends one; whether
  ospfd should is open question 6.

#### As built, step 2

- **The codec** is `core/tlv.rb` and `core/router_information.rb`,
  built to protocol-conventions part 1. Each TLV is built from field
  values, a Hash, its octets or another instance, and all four give the
  same `encode`. Each has `to_hash`, `to_s` and `to_shex`. Types come
  from a registry (`RouterInformation::TLVS`, `SUB_TLVS`), and an
  unknown one is kept as `Tlv::Unknown` with its octets. Building
  never validates. Step 3's TLVs use the same base.
- **Ours.** While opaque is on, each area has our RI LSA: type 10,
  4.0.0.0, the capabilities TLV with no bits set. `Instance#sr_capabilities=`
  adds SR-Algorithm, one SID/Label Range per SRGB range in order, and
  one SRLB TLV per range; step 4 sets it from the configuration.
  `opaque_lsas=` refuses 4.0.0.0: it is ospfd's own. Turning opaque
  off flushes it.
- **Reading.** `Instance#router_information(area)` gives each router's
  capabilities, algorithms, SRGB, SRLB and findings, under the receive
  policy:
  - of several RI LSAs from one router, the lowest opaque ID with an
    SR-Algorithm TLV gives SR's values;
  - only the first SR-Algorithm TLV counts (`sr_algorithm_twice`,
    `:use_first`); under `:strict` the router is left out of SR;
  - a range of size 0, or with two SID/Label sub-TLVs, is left out;
  - no SR-Algorithm TLV: `algorithms` nil, not SR capable (RFC 8665
    section 3.1).

  Reachability (RFC 5250 section 3.1) is left to step 4's calculation,
  which reads only routers SPF reaches.
- **A new rule, `range_two_sid_labels`** (RFC 8665 sections 3.2 and
  3.3), with its fault catalog entry. Overlapping ranges follow RFC
  8660's procedure; that is step 4's, with the labels.
- **A malformed opaque LSA is dropped on receipt.** An RI, extended
  prefix or extended link LSA with a TLV past its end is not stored,
  acknowledged or reflooded (`tlv_overrun`, RFC 7684 section 5), as
  step 0 said step 1 would act on it.
- **`show.database` with `detail`** decodes an RI body: `opaque_type`,
  `opaque_id` and the TLVs' `to_hash`. A malformed body gives `error`.
- **MinLSArrival.** A flush that comes within a second of the LSA it
  flushes is discarded by the receiver (RFC 2328 13 (5a)), which then
  keeps the LSA until MaxAge. Turning opaque off can leave a
  neighbor's copy of our RI so; the tests wait past MinLSArrival.
- **The tests** (`test/unit/core/router_information_test.rb`): each
  TLV four ways against octets worked out from the RFCs; an unknown
  TLV (RFC 9350's FAD, type 16) kept; RFC 8665 section 3.2's three
  ranges kept in order; ours in the area and flushed; SR's TLVs sent
  and read; each finding's effect under `:rfc`, and `:strict`'s; a
  malformed one dropped. The step 1 tests moved from opaque type 4 to
  type 1, since 4.0.0.0 is now ospfd's.
- **Interop with FRR** (`frr_interop_test.rb`, in CI): with
  `segment-routing on` and a global and local block on FRR, FRR's JSON
  shows ospfd's SRGB and SRLB, ospfd reads FRR's, and FRR's RI octets
  go through ospfd's codec unchanged.
- **Padding, measured.** FRR 10.5.1 pads its SR-Algorithm TLV with
  `ff ff ff`, not zeros. RFC 7770 section 2.3 allows it: the padding
  "is composed of undefined bits". The first CI run failed on it, since
  the codec re-encoded zeros. A parsed TLV now keeps the padding it came
  with; a built one pads with zeros. FRR's octets are a unit test.
- **Not done here:** RFC 8665 section 3.2's example as labels (index
  100 is label 1000) is step 4's calculation.

### Step 3: extended prefix and extended link (RFC 7684)

- **Extended prefix LSA**: opaque type 7, LS type 10 or 11 (section 2).
  Its TLV 1, Extended Prefix: route type, prefix length, AF 0, flags
  (A 0x80, N 0x40), a 4-octet prefix, then sub-TLVs (2.1).
- **Extended link LSA**: opaque type 8, LS type 10 (section 3). One
  Extended Link TLV per LSA: "Only one OSPFv2 Extended Link TLV SHALL be
  advertised in each OSPFv2 Extended Link Opaque LSA" (3.1). Link type,
  3 reserved octets, link ID, link data, sub-TLVs, matching a link of
  the router-LSA.
- **Opaque IDs.** ospfd gives one extended prefix LSA per prefix with
  attributes, and one extended link LSA per link, each with an opaque
  ID kept while the prefix or link exists. That makes a change one small
  LSA, as 3.1 wants for links. Whether to pack prefixes instead is open
  question 3.
- **Reading.** For the same prefix or link in several LSAs of one
  router, the lowest opaque ID wins (2 and 3). The same TLV twice in one
  LSA: the first is used and the second is a finding (2.1, 3.1:
  "SHOULD be logged as an error").
- **Sub-TLVs are a registry too.** P9 adds the Flexible Algorithm
  Prefix Metric sub-TLV to the Extended Prefix TLV (RFC 9350 section
  9, type 3 for OSPFv2), and RFC 9492 adds the Application-Specific
  Link Attributes sub-TLV to the Extended Link TLV (section 5). Unknown
  sub-TLVs are kept and replayed.
- Nothing is originated in this step without SR: an extended prefix or
  link LSA with no sub-TLVs says nothing. The codec and the reading
  land here; origination comes with step 4.

#### As built, step 3

- **The codec** is `core/extended.rb`, on step 2's `Tlv`, with a body
  class both share (`Tlv::Body`):
  - `ExtendedPrefix`: opaque type 7, the Extended Prefix TLV (route
    type, prefix, AF, flags A and N) and its Prefix-SID sub-TLV (RFC
    8665 section 5: flags, MT-ID, algorithm, SID);
  - `ExtendedLink`: opaque type 8, the Extended Link TLV (link type,
    ID, data) and its Adj-SID and LAN Adj-SID sub-TLVs (6.1, 6.2).

  A SID is 3 octets with the V flag set and 4 without; a parsed one
  keeps the size it came in, so a SID wrong on purpose goes back as it
  came. Sub-TLVs are registries too, so RFC 9350's Prefix Metric and
  RFC 9492's ASLA sub-TLVs are kept as `Unknown` until P9 reads them.
- **Reading.** `Instance#extended_prefixes(area)` and
  `#extended_links(area)` give each router's, from the area's type 10s
  and the AS's type 11s:
  - a prefix or link in several LSAs of one router takes the lowest
    opaque ID (RFC 7684 sections 2.1, 3.1);
  - one twice in one LSA takes the first, with a finding;
  - a Prefix-SID with V and L unequal is left out (RFC 8665 section 5).
- **Two new rules**, each with its fault catalog entry:
  `prefix_tlv_twice` and `link_tlv_twice` (RFC 7684 sections 2.1 and
  3.1, "SHOULD be logged as an error"). Their action is `:use_first`,
  and `:ignore_lsa` under `:strict`. They are in the `opaque` group:
  RFC 7684's, not SR's.
- **Nothing is originated** in this step, as the spec says.
- **`show.database` with `detail`** decodes both kinds.
- **The tests** (`test/unit/core/extended_test.rb`): each TLV and
  sub-TLV four ways against octets worked out from the RFCs; an unknown
  sub-TLV kept; the lowest opaque ID; a SID left out; one prefix twice;
  two links, under `:rfc` and `:strict`; the detail.
- **Interop with FRR** (in CI): with `segment-routing prefix 2.2.2.2/32
  index 2`, ospfd reads FRR's Prefix-SID 2 and its Adj-SID to ospfd,
  and FRR's octets of both go through the codec unchanged. The test
  prints them; FRR 10.5.1's are kept in `extended_test.rb`. As the DR
  on the broadcast link, FRR sends its extended link as a transit link
  with two LAN Adj-SIDs to ospfd, one with B (0xe0) and one without.
  It does so without TI-LFA configured, as routescope found for 10.2.1.

### Step 4: SR-MPLS (RFC 8665)

#### Wire format

| Where | Type | Name | RFC 8665 |
| --- | --- | --- | --- |
| RI LSA | 8 | SR-Algorithm | 3.1 |
| RI LSA | 9 | SID/Label Range | 3.2 |
| RI LSA | 14 | SR Local Block | 3.3 |
| Range and SRLB TLVs | 1 | SID/Label | 2.1 |
| Extended Prefix TLV | 2 | Prefix-SID | 5 |
| Extended Link TLV | 2 | Adj-SID | 6.1 |
| Extended Link TLV | 3 | LAN Adj-SID | 6.2 |

Points the classes must keep:

- **SID/Label** is 3 octets (a label in the 20 rightmost bits) or 4 (a
  32-bit SID) (2.1).
- **Prefix-SID**: flags, reserved, MT-ID, algorithm, then 4 octets of
  index with V and L clear, or 3 octets of label with both set. Flags
  NP 0x40, M 0x20, E 0x10, V 0x08, L 0x04. "All other combinations of
  V-Flag and L-Flag are invalid and any SID Advertisement received with
  an invalid setting ... MUST be ignored" (5).
- **Adj-SID**: flags B 0x80, V 0x40, L 0x20, G 0x10, P 0x08, reserved,
  MT-ID, weight, then the SID as in 5 (6.1). **LAN Adj-SID** adds the
  neighbor's router ID before the SID (6.2).
- A bad length in any of these "the LSA in which it is advertised is
  considered malformed and MUST be ignored" (section 9). So the whole
  LSA is left out of SR, a finding, logged at a limited rate. It is
  still stored and flooded: RFC 5250 section 3 says the receiver "must
  always store a valid received Opaque LSA".
- Building never validates, as in isis: the parse keeps the octets, and
  validation says what is wrong. The fault catalog needs wrong values.

The Extended Prefix Range TLV (section 4) and the SRMS Preference TLV
(3.4) are the mapping server's: decoded, kept, not acted on.

#### Configuration

Junos style, as the rest of ospfd. Juniper's statement is `source-packet-routing`
under `protocols ospf`
([reference](https://www.juniper.net/documentation/us/en/software/junos/cli-reference/topics/ref/statement/source-packet-routing-edit-protocols-ospf.html));
the exact leaves are checked against that page before the schema is
written.

```
set protocols ospf source-packet-routing srgb start-label 16000 index-range 8000
set protocols ospf source-packet-routing srlb start-label 15000 index-range 1000
set protocols ospf source-packet-routing node-segment ipv4-index 1
set protocols ospf area 0.0.0.0 interface lo passive
set protocols ospf area 0.0.0.0 interface eth1 no-adjacency-sid
```

- **No `source-packet-routing` means SR off**, and opaque off unless
  open question 1 says otherwise. Every LSA stays as today.
- **`srgb`**: one range here. Several ranges are allowed on the wire
  and read in order; configuring several is open question 4. The
  default is 16000, 8000, FRR's and isisd's. Ranges must not overlap
  each other or labels 0 to 15. A bad SRGB refuses the commit
  (`config/model.rb`).
- **`srlb`** has no Junos statement in that reference that I have
  checked. It is ospfd's own, as `local-block` is FRR's; open question
  4.
- **`node-segment ipv4-index`** is the index on the router ID's /32,
  which must be a passive interface's address. N is set (RFC 7684
  section 2.1). Other prefixes get a SID with a per-prefix statement,
  later, as Junos has one; the first version has the node SID only.
- **Adj-SIDs** are on by default on every interface in an area, and
  off with `no-adjacency-sid`.

#### Origination

- **The RI LSA** of step 2, in every area.
- **Prefix-SID**, intra-area: an extended prefix LSA, type 10, route
  type 1, N set, with the Prefix-SID: algorithm 0, MT-ID 0, an index.
  NP and E clear by default (PHP).
- **Inter-area** (RFC 8665 section 7.2): an ABR that originates a
  type 3 for a prefix also originates an extended prefix LSA in the
  other area, route type 3, with the SID of the router on its best path
  in the source area, or any router's if that one gave none. NP set and
  E clear "unless the advertised prefix is directly attached to the
  ABR" (5). A summarized range carries no SID, as in isis.
- **External** (7.3): an ASBR that originates a type 5 with a SID
  originates a type 11 extended prefix LSA, route type 5, NP set and E
  clear unless the prefix is attached (5). An NSSA translator passes
  the SID on. ospfd's exports carry no SID in the first version, so this
  is reading only until a policy action sets one; open question 5.
- **Adj-SID** (7.4.1): on a point-to-point link, one per neighbor in
  state 2-Way or above; withdrawn below 2-Way ("MUST be withdrawn").
  V and L set, a 3-octet label from the SRLB, kept while the adjacency
  lives. P clear, so a restart may change it (6.1 allows that).
- **Broadcast** (7.4.2): the Adj-SID for the adjacency to the DR in the
  extended link LSA of the transit link, and a LAN Adj-SID for each
  other Full neighbor. Whether FRR sends LAN Adj-SIDs is measured in
  the interop lab and written here.

#### As built, pull request 4: configuration and origination

- **The leaves, checked** (2026-11-27) against Juniper's
  `source-packet-routing` (Protocols OSPF) page. It gives
  `node-segment` with `ipv4-index` and `index-range` (an index range,
  32 to 16384, default 4096), `adjacency-segment hold-time`,
  `explicit-null` and `disable`. It has no `srgb`, no SRLB statement
  and no per-interface `no-adjacency-sid`. Cisco has all three: IOS
  XE's `segment-routing mpls` with `global-block`, IOS XR's
  `segment-routing global-block` and `local-block`, and a prefix-SID
  and Adj-SID per interface. The owner chose the draft's leaves
  (2026-11-27): `node-segment ipv4-index` as Junos has it, `srgb`,
  `srlb` and `no-adjacency-sid` as ospfd's own, documented so.
- **The model** (`config/model.rb`) gives `sr: { srgb:, srlb:, index:,
  no_adj_sid: }`, with the defaults, and refuses blocks that overlap,
  pass label 1048575, or an index past the SRGB. The SRGB's first label
  is 16 or more, past the reserved labels.
- **SR turns opaque on.** The daemon sets `opaque` from `opaque` or
  `source-packet-routing`, and `Instance#segment_routing=` from the
  model. Off, every LSA is as before.
- **The RI LSA** carries SR-Algorithm 0, the SRGB and the SRLB.
- **The Node-SID**: an extended prefix LSA, 7.0.0.1, route type 1, N
  set, NP and E clear, in the area of the passive interface that holds
  the router ID's /32, as FRR does. Without such an interface, none.
  The router ID's /32 is checked when the area originates, since the
  configuration does not know addresses.
- **Adj-SIDs follow the router-LSA's links**, so each extended link
  LSA matches a link there (RFC 7684 section 3.1): on point-to-point,
  one per full neighbor; on a transit link, an Adj-SID to the DR and a
  LAN Adj-SID for each other full neighbor. 7.4.1 says 2-Way or above;
  a point-to-point neighbor has no router-LSA link below Full, so Full
  it is. A label from the SRLB is kept while the adjacency lives and
  let go after; the lowest free one is taken. V and L set, B and P
  clear: no backup Adj-SID, as FRR sends, until TI-LFA.
- **Opaque IDs.** One extended link LSA per link, its opaque ID the
  lowest free in the area, kept while the link exists.
  `opaque_lsas=` refuses opaque types 7 and 8: they are ospfd's own.
- **Inter-area SIDs move to pull request 5.** An ABR's extended prefix
  LSA for a type 3 needs the SID of the route's advertising router,
  which the calculation finds. External SIDs stay reading-only, as
  said.
- **The tests** (`test/unit/core/sr_origination_test.rb`): the RI's
  blocks, the Node-SID, an Adj-SID per point-to-point neighbor, the
  Adj-SID withdrawn with the adjacency and its label taken again, no
  Node-SID without a passive /32, `no-adjacency-sid`, a LAN of three
  (the DR's LAN Adj-SIDs; the BDR's Adj-SID to the DR and LAN Adj-SID
  to the DROther), SR off. The model's defaults and refusals, and the
  daemon from the statement to a peer's reading.
- **Interop with FRR** (in CI, FRR 10.5.1): FRR's `show ip ospf
  database segment-routing json` lists ospfd with its SRGB, SRLB,
  Node-SID and its Adj-SID, 15000. FRR also lists, for the same link, a
  second entry with `sid` 0 and next hop 0.0.0.0: an empty slot for the
  backup Adj-SID FRR itself sends and ospfd does not. Measured on the
  first CI run, whose test expected none.

#### Calculation

A step after each SPF run, as isis's `Spf::Labels`. It does not change
SPF.

1. **Each router's SR state** in each area: its SRGB, SRLB and
   algorithms from its RI LSA (step 2), and only for a router SPF
   reaches (RFC 5250 section 3.1: "SHOULD only be used when the router
   originating the LSA is reachable").
2. **Each route keeps who advertised it** and the Prefix-SID that
   router gave the prefix. `Spf` today keeps the route's area and
   next hops; it gains the advertising router for intra-area routes,
   the ABR for inter-area ones, the ASBR for externals. A Prefix-SID for
   an algorithm its router did not advertise is ignored (5). Several
   Prefix-SIDs for one prefix, topology and algorithm from one router:
   "all of them MUST be ignored" (5).
3. **Labels for a route with index I**:
   - In-label: I in our SRGB, by RFC 8660 section 2.4's formula.
   - For each next hop N, by its router ID:
     - N advertised the SID and NP is clear: pop (implicit null).
     - N advertised it with NP and E set: explicit null, 0.
     - Otherwise: I in N's SRGB. N with no SRGB, or I past its end: no
       label on that next hop, the IP route stays, a finding (RFC 8660
       section 2.10.1).
   - RFC 8665 section 5 says the flags of N count "regardless of
     whether the next-hop router contributes to the best path". That
     is the case where N advertises the prefix too, though not on the
     best path. The test list has it.
4. **Our own prefix**: a pop label only with NP set, as isisd and FRR
   10.2.1 do (isis `docs/design/sr-mpls.md`, "Measured on FRR 10.2.1").
5. **Each Adj-SID of ours**: pop, out of its adjacency (RFC 8660
   section 2.11).

The result is the same shape as isisd's: `{label:, op: :swap | :pop,
next_hops: [{interface:, address:, out_label:}]}` per in-label, and an
out-label per next hop on each IP route.

**Collisions.** Two prefixes with one index, or an index past our SRGB:
no label for either, a finding and an event, as isisd does (isis open
question 2 still stands). RFC 8660 section 2.5.1's tie-breaking (lowest
administrative distance, then lowest FEC) is read; adopting it is open
question 2 here, to match whatever isis decides.

**Areas.** A prefix reached in several areas gives one route; its
labels follow that route's area. No per-area label tables.

#### Forwarding

Ported from isisd's, not shared: ospfv2 takes no gem but bfd4r
(`CLAUDE.md`). Whether this code moves into a shared gem is
protocol-conventions' open question 5, not this spec's.

- `fib/netlink.rb` gains label routes (`AF_MPLS`, `RTA_DST` the label,
  `RTA_VIA`, `RTA_OIF`, `RTA_NEWDST` for a swap) and MPLS encap on IP
  routes (`RTA_ENCAP_TYPE`, `RTA_ENCAP` with `MPLS_IPTUNNEL_DST`). isis
  `forwarding/netlink.rb` `label_message` and `encap` are the model; its
  message bodies were checked against what iproute2 6.19 sends,
  captured with strace. ospfd's tests compare the same way.
- `fib/manager.rb` diffs the label table as it diffs routes, with
  ospfd's protocol id (89 by default). Old label routes of that id are
  flushed at start, as isisd's are. ospfd's rule holds: it touches only
  its own routes.
- `fib/memory.rb` keeps labels too, so the unit tests see them.
- **The host.** As isisd's `Router::Host#mpls`: set
  `net.mpls.conf.IF.input` on ospfd's interfaces, check
  `net.mpls.platform_labels` above the top of the SRGB and SRLB.
  Without them ospfd logs why, keeps advertising SIDs, and installs IP
  routes only. The VMs load `mpls_router` and `mpls_iptunnel` at boot
  (routescope `docs/sr-mpls.md`).

#### API and CLI

Additive, and listed in `api.info`:

- `show.routes`: `sid` on a route, `label` on a next hop.
- `show.labels`: the label table, as the kernel should have it.
- `show.segment_routing`: on or off, our SRGB, SRLB and Adj-SIDs, and
  each router's SRGB, SRLB, algorithms and Node-SID, per area, with
  the label we take each Node-SID in. The same fields as isisd's, with
  `area` in place of `level`.
- `show.fib`: label routes against the kernel, as IP routes are.
- `show.topology`: each prefix's `sid` and each router's `srgb`.
- A new event kind, `sr_finding`. No `label_change`: routescope re-reads
  the labels on an `spf` event (its `docs/design/sr-ospf-views.md`).
  The shapes of these calls are in "Answers for routescope", below.
- ospf-cli: `show ospf segment-routing`, `show mpls label` in Junos
  form, and the IOS forms.

### Step 5: the simulator

So the simulator can send SR LSAs behind the DUT, as isis4r-sim does:

- **The codec.** A registry of opaque types in `lsa_factory.rb`, with
  `Unknown` kept as octets, in place of the `case` that returns nil.
  New classes: `RouterInformation` (opaque type 4), `ExtendedPrefix`
  (7), `ExtendedLink` (8), and their TLVs and sub-TLVs in `lsa/tlv/`,
  each built four ways with `to_hash` and a round-trip catalog entry
  (protocol-conventions part 1). The TLV and sub-TLV factories become
  registries; an unknown type no longer raises.
- **The O bit** in its DD options when the topology has SR. Not in its
  Hellos.
- **The topology file**, as isis4r-sim's: a `segment_routing` block
  turns SR on with a default SRGB; `grid.sids` numbers the grid's
  loopbacks; a router takes `sid` and its own `srgb`. Each simulated
  router gets an RI LSA, an extended prefix LSA for its loopback, and
  an extended link LSA per link with an Adj-SID.
- **Faults.** `/api/fault` sends the SR catalog entries of step 0. LSA
  actions (`/api/lsa/refresh`, `/flush`) take opaque LSAs.
- The simulator installs nothing.

The simulator's thread-per-timer stack is its own topic (`REVIEW.md`,
items 3 and 4). This step adds to it and does not rewrite it.

### Step 6: TI-LFA, out of this spec

TI-LFA in ospfd is a spec of its own, after this one. The reasons:

- It needs SR-MPLS whole first: label routes and adj-SIDs are its
  repair path.
- ospfd has no loop-free alternates of any kind today. isis needed a
  spec of its own (routescope `docs/design/ti-lfa.md`), a step 0 of
  conventions, and six steps.
- The computation is protocol-free; isis's `spf/ti_lfa.rb` and RFC
  9855's figures are the model. How to reuse it is that spec's
  question.
- FRR's ospfd has `fast-reroute ti-lfa [node-protection]` in 10.2.1 and
  10.7.1, so the interop check exists when it comes.

This spec keeps room for it: the label table's next hop can take a
backup later, as isisd's does, and the Adj-SID B flag stays clear until
then.

## routescope

routescope's side is a spec of its own, in routescope, after ospfv2's
step 4. What an OSPF row needs, from what it shows for isis4r and FRR
today (routescope `docs/sr-mpls.md`):

- **`mpls_labels`**: the same columns, from ospfd's `show.labels`
  checked against `ip -j -M route`, and from FRR's `show mpls table
  json`. The Kernel check counts routes of ospfd's protocol id. On
  FRR, the extra-protocol list gains `ospf`.
- **`sr_nodes`**: today keyed by `level`. An OSPF row needs `area` in
  its place. ospfd's `show.segment_routing` gives it; FRR's `show ip
  ospf database segment-routing json` is recorded from FRR 10.2.1
  first, as the IS-IS fixtures were.
- **`routes`** (OSPF): a `sid` column and each next hop's label,
  optional as on `isis_routes`.
- **`neighbors`** (OSPF): an `adj_sid` column, optional, and `opaque`.
- **`lsdb`**: types 9 to 11 rows, with `opaque_type`, `opaque_id` and,
  for type 9, the interface.
- **Gating**: today `sr_table?` asks `isis?`. It becomes "this node
  runs SR in IS-IS or OSPF", from `show.segment_routing` on ospfd and
  the RI LSA on FRR.
- Scenarios: `mpls_label` works as is; `ospf_route` gains `label`.

routescope's spec is `docs/design/sr-ospf-views.md` (routescope #319).
It recorded these on FRR 10.2.1; the interop step checks against them:

- FRR sends two Adj-SIDs per adjacency without TI-LFA: one with flags
  0xe0 (B, V, L) and one with 0x60 (V, L).
- With SR off, `show ip ospf database segment-routing json` prints the
  text "Segment Routing is disabled on this router", not JSON.
- `show ip ospf database json` lists FRR's opaque LSAs under
  `areaLocalOpaqueLsa`.
- FRR's label routes have kernel protocol `ospf`.

## Answers for routescope

routescope's `docs/design/sr-ospf-views.md`, "Questions for ospfv2",
asks eight questions about calls this spec names. These are the
answers. Every shape is additive; nothing that exists is renamed. Where
a call exists today, what it gives was read from the code at ospfv2
`5b005c5`, 2026-11-25.

1. **`show.segment_routing`**, one object:

   ```json
   {
     "enabled": true,
     "srgb": [{ "start": 16000, "size": 8000 }],
     "srlb": { "start": 15000, "size": 1000 },
     "adj_sids": [
       {
         "interface": "eth1",
         "neighbor": "10.255.0.2",
         "address": "10.0.12.2",
         "label": 15000,
         "flags": ["V", "L"],
         "weight": 0,
         "lan": false
       }
     ],
     "nodes": [
       {
         "area": "0.0.0.0",
         "router_id": "10.255.0.2",
         "self": false,
         "srgb": [{ "start": 17000, "size": 8000 }],
         "srlb": { "start": 15000, "size": 1000 },
         "algorithms": [0],
         "node_sid": { "prefix": "10.255.0.2/32", "index": 2, "label": 16002 }
       }
     ],
     "findings": []
   }
   ```

   A node row is keyed by area and router ID. There is one for every SR
   router SPF reaches, ours included (`self: true`), with its SRLB and
   Node-SID, as isisd gives them from isis #92. `node_sid.label` is the
   label this router takes it in, from our SRGB. A router with no SRLB
   has no `srlb` key. The Adj-SIDs are ours only, one row per interface
   and neighbor router ID; `lan: true` marks a LAN Adj-SID.

2. **`show.database` with `detail: true`** gives decoded TLVs, never
   raw octets, for opaque types 4, 7 and 8. Flags are the RFC's
   letters, as isisd gives them. An unknown TLV, or an opaque type
   ospfd does not decode, gives `type` and `hex`. The decoding lives in
   `Core::Lsa#detail`, so the simulator's `GET /api/lsdb?detail=1` gives
   the same shape.

   ```json
   {
     "opaque_type": 4,
     "opaque_id": 0,
     "tlvs": [
       { "type": 1, "name": "informational-capabilities", "bits": [] },
       { "type": 8, "name": "sr-algorithm", "algorithms": [0] },
       { "type": 9, "name": "sid-label-range", "size": 8000, "label": 16000 },
       { "type": 14, "name": "srlb", "size": 1000, "label": 15000 }
     ]
   }
   ```

   ```json
   {
     "opaque_type": 7,
     "opaque_id": 1,
     "tlvs": [
       {
         "type": 1,
         "name": "extended-prefix",
         "route_type": 1,
         "prefix": "10.255.0.1/32",
         "af": 0,
         "flags": ["N"],
         "sub_tlvs": [
           { "type": 2, "name": "prefix-sid", "flags": [], "mt_id": 0, "algorithm": 0, "index": 1 }
         ]
       }
     ]
   }
   ```

   ```json
   {
     "opaque_type": 8,
     "opaque_id": 3,
     "tlvs": [
       {
         "type": 1,
         "name": "extended-link",
         "link_type": "p2p",
         "link_id": "10.255.0.2",
         "link_data": "10.0.12.1",
         "sub_tlvs": [
           { "type": 2, "name": "adj-sid", "flags": ["V", "L"], "mt_id": 0, "weight": 0, "label": 15000 }
         ]
       }
     ]
   }
   ```

   A SID is `index` when V and L are clear and `label` when both are
   set. An invalid pair gives `value` and `finding`. A LAN Adj-SID adds
   `neighbor`. `name` is the registry name with hyphens, the same word
   as the dissector's `key` (answer 7).

3. **The kernel protocol id** is `protocol` in `show.fib`, and
   `fib.protocol` in `show.overview`, today (`daemon/views.rb`, `fib`
   and `fib_summary`). It is 89 unless `routing-options kernel
   protocol` sets another. Label routes take the same id.

4. **`POST /api/fault`** on the simulator takes `name`, the catalog
   entry, and the parameters that entry names: `router` (a topology
   router's name), `prefix`, `index`, `neighbor`, `area`. An unknown
   name or a missing parameter is a 400 whose `error` lists what it
   takes. `GET /api/info` lists the route: its list comes from the table
   that serves the routes (`web/server.rb`, `ROUTES`).

5. **`GET /api/lsdb` for types 9 to 11.** The simulator keeps its own
   names, printed from `LsType` today: `type` is `link_local`, `area`
   or `domain`, and `type_name` is `OpaqLoca`, `OpaqArea` or `OpaqAS`.
   Its rows gain `opaque_type` and `opaque_id`, as ospfd's do.

6. **The simulator's SIDs** are in `GET /api/state`, on the nodes of
   `graph`: a simulated router with SR gains `srgb` (a list of
   `{start, size}`, as in answer 1) and `sid`, its loopback's index.
   Without SR, the nodes are as today.

7. **The dissector** decodes the RI, extended prefix and extended link
   TLVs and their sub-TLVs as nested fields with offsets, as it does a
   router-LSA's links. Each TLV and sub-TLV field carries `key` beside
   `name`, nothing renamed, as isis #135 asks: `router-information`,
   `sr-algorithm`, `sid-label-range`, `srlb`, `extended-prefix`,
   `prefix-sid`, `extended-link`, `adj-sid`, `lan-adj-sid`. Other TLVs
   stay one hex field. This comes with step 3's codec.

8. **The `sr_finding` event**: kind `sr_finding`, level `warn`, and
   `data` with `finding` (its name in `validation.rb`), `rfc` (the
   section, as `"RFC 8665 5"`), `action` (what was done: `ignored` or
   `no_label`), `area`, `router_id` (the LSA's advertising router), and
   `lsa`: `{type, ls_id, advr}`, the fields `show.database` rows carry,
   so the timeline can link to it. One event when a finding first
   appears, not one per SPF run. It goes into `api.info`'s
   `event_kinds` and the README's table.

## Labs

Built to the owner's rule: our own Ruby code first, other daemons for
interop.

- **`ospf-sr`**, in `routescope/labs/`: four ospfd routers in a line,
  one area, different SRGBs (16000, 17000, 18000, 19000) so a label
  from the wrong block shows, a loopback with a Node-SID on each. The
  main lab. Its `ABOUT.md` says so.
- **`ospf-sr-frr`**, the interop lab, on FRR 10.2.1, the version
  ospfv2's labs and CI pin:

```
f1 ---- o1 ---- o2 ---- f2
FRR     ospfd   ospfd   FRR
16000   17000   18000   16000     SRGB start
idx 1   idx 2   idx 3   idx 4     Node-SIDs
```

  The same shape as isis's `isis4r-sr`, so the two walk-throughs read
  alike. 10.7.1 is on the VM too; moving the pin is not this spec's
  topic.
- A third lab with two areas, for inter-area SIDs (7.2), after the
  first two pass. Open question 7.
- Both need `mpls_router` and `mpls_iptunnel`, and set
  `net.mpls.platform_labels` and `net.mpls.conf.IF.input` in each
  node's `exec`, as routescope's `frr-sr` lab does.

## Tests

The four tiers of protocol-conventions part 10.

- **Unit, codec**: hex both ways for every TLV and sub-TLV; the RI LSA
  and both extended LSAs built four ways; an unknown opaque type, TLV
  and sub-TLV kept and replayed; RFC 8665 section 3.2's three-range
  example (index 100 is label 1000, index 200 is label 500).
- **Unit, core, on the fake clock** (`Hub` and `Clock::Fake`):
  - two ospfd instances reach Full with O set; a type 10 floods; a type
    11 does not enter a stub area; a type 9 stays on its interface; a
    neighbor without O gets no opaque LSA on its retransmission list;
  - with opaque off, the DD options and every LSA are what they were;
  - a type 11 from an unreachable ASBR is not used (RFC 5250 section 5).
- **Unit, calculation**: PHP; NP keeps the label; NP and E give 0; a
  neighbor with another SRGB; a neighbor with none; ECMP, one out-label
  per next hop; an algorithm the router did not advertise; two SIDs for
  one prefix from one router; a SID from a router SPF does not reach;
  an inter-area SID through an ABR with NP set; a next hop that
  advertises the prefix off the best path (RFC 8665 section 5).
- **Unit, validation and faults**: each catalog entry gives the finding
  the catalog says, under `:rfc`.
- **Unit, forwarding**: netlink octets for a push, a swap and a pop,
  each against iproute2's (strace, as isis did).
- **Interop**, in network namespaces, as `test/integration/
  frr_interop_test.rb` today, `OSPFV2_FRR=1`: ospfd and FRR exchange
  opaque LSAs; FRR lists ospfd's SRGB and SIDs; labels match.
- **Lab**: `test/lab/sr_test.sh`, the gate below.

## Gates

- **Step 1**: ospfd and FRR 10.2.1 Full with opaque, each listing the
  other's type 10 LSAs.
- **Step 2 and 3**: FRR decodes ospfd's RI, extended prefix and extended
  link LSAs (`show ip ospf database opaque-area json`), and ospfd
  decodes FRR's.
- **Step 4**, on `ospf-sr-frr`: f1 pings f2's loopback from its own; on
  o1, `tcpdump` shows 17004 in and 18004 out; o2 pops. The reply comes
  back the same way. o1's `show.labels` matches `ip -M route` in its
  container. A link flap leaves no stale label. FRR's `show ip ospf
  database segment-routing` lists o1 and o2 with their SRGBs.
- **Step 5**: FRR beside the simulator labels every grid SID through
  the simulator, from the simulator's SRGB.

## Pull requests

One topic each, in ospfv2, in this order:

0. `validation.rb`, the receive policy, `OSPFv2::Fault` with the
   opaque and SR entries, `/api/fault`.
1. Opaque LSAs in the core.
2. The RI LSA, its codec and origination.
3. The extended prefix and link LSAs, codec and reading.
4. SR: configuration and origination.
5. SR: calculation and API.
6. SR: forwarding.
7. The simulator.
8. The labs and `test/lab/sr_test.sh`.

Then routescope's spec and its pull requests.

## P9 and this spec

P9 (flex-algo, RFC 9350 and RFC 9492) needs, from this spec:

- the RI LSA with a TLV registry, for the FAD TLV (RFC 9350 section
  5.2, type 16);
- the extended prefix TLV with a sub-TLV registry, for the Prefix Metric
  sub-TLV (section 9);
- the extended link TLV with a sub-TLV registry, for ASLA (RFC 9492
  section 5);
- a new opaque LSA, the Extended Inter-Area ASBR LSA (RFC 9350 section
  10.1), which the opaque-type registry of step 1 takes;
- the SR-Algorithm TLV read as a list, not as `[0]`.

FRR's ospfd has no flex-algo in 10.2.1 or 10.7.1 (measured above).
So P9's interop check in OSPF needs another router; open question 8.

## Out of scope

Each later, with its own spec:

- TI-LFA and the B flag (step 6 above);
- the mapping server: the Extended Prefix Range TLV and SRMS
  Preference are decoded, not acted on;
- persistent Adj-SIDs (the P flag);
- multi-topology (MT-ID other than 0);
- algorithms other than 0, and flex-algo (P9);
- SRv6 (RFC 9513), which is for OSPFv3 and needs OSPFv3 first; ospfd
  is OSPFv2, IPv4 only;
- SR-LDP interworking;
- BGP-LS SR for OSPF: `core/lsdb_topology.rb` gains SIDs when bgp4r's
  Producer asks for OSPF ones;
- TE LSAs in ospfd (RFC 3630).

## Open questions for the owner

1. **Opaque without SR.** Turn on the O bit and opaque storage only with
   SR, or by its own statement too (as FRR's `capability opaque`)?
   The draft: with SR, and by a statement, so opaque can be tested alone.
2. **Label collisions.** Drop both sides with a finding, as isisd does,
   or RFC 8660 section 2.5.1's tie-breaking? The draft follows isis's
   answer, whichever it is.
3. **Extended prefix LSAs.** One per prefix (small changes, more LSAs)
   or packed (fewer LSAs)? The draft: one per prefix.
4. **Configuration.** Several SRGB ranges, and an SRLB statement Junos
   may not have: ospfd's own leaves, or one range and a fixed SRLB in
   the first version? The draft: one range each, both configurable.
5. **SIDs on exports.** A policy action that gives an exported prefix a
   SID (RFC 8665 section 7.3), in this spec or later? The draft: later.
6. **Node MSD (RFC 8476 section 2).** Advertise it in the RI LSA, as FRR
   does in IS-IS? The draft: not in the first version.
7. **The two-area lab.** In this spec's gates, or after them? The
   draft: after.
8. **P9's interop.** FRR's ospfd has no flex-algo. Which released
   router does P9 test OSPF flex-algo against, or does it test against
   isis's FRR interop only and ospfd against itself?
9. **Shared SR code.** The label calculation and netlink code are
   ported from isis. Copy them, as this draft does, or wait for
   protocol-conventions' open question 5 (a small shared gem)?
