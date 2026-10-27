# ospfv2

Simulate an OSPFv2 area behind a single adjacency.

`ospfv2` brings up an OSPF neighbor with a router under test (the DUT) and floods a
synthetic link state database behind it. Use it to load a router with thousands of
LSAs, flap links and watch SPF, or check how a router handles summaries and externals.

It targets Ruby 3.1 and later (CI covers 3.2 to 4.0), uses the standard library only,
and ships as a Docker image.

A second mode is on its way: `ospfd`, an OSPFv2 router you configure and query with
`ospf-cli` in Junos or IOS terms. It forms adjacencies, floods, authenticates,
computes routes and installs them in the Linux routing table. See
[Router mode](#router-mode-ospfd-and-ospf-cli).

## Quick start

```sh
ospfv2 demo --web 8080          # no router, no root: a built-in peer plays the DUT
```

Open http://localhost:8080. You get the adjacency state, the topology graph, every
link with an up/down switch, the LSDB and an event log.

Against a real router:

```sh
ospfv2 init --grid 4x4 > lab.yml     # starter topology, edit interface and router ids
ospfv2 check lab.yml                 # validate, count routers and LSAs
sudo ospfv2 run lab.yml --web 8080   # raw sockets need root or CAP_NET_RAW
```

Without `--web`, `run` opens an interactive console. Type `help` there.

## Topology files

A topology describes the simulated router and the area behind it.

```yaml
simulator:
  router_id: 1.1.1.1
  interface: 192.168.1.123/24   # our address on the segment shared with the DUT
  area: 0.0.0.0
  hello_interval: 10            # must match the DUT; dead_interval defaults to 4x
  network_type: broadcast       # or p2p
  # device: eth1                # bind the raw socket to one interface
  # attach_to: r1c1             # router linked to the simulated router, or none

lsdb:
  link_prefix: 13.0.0.0/30      # router-to-router links are carved from here
  refresh_time: 1800            # re-originate LSAs older than this, in seconds

grid:                           # optional: routers r<row>c<col>, id 0.<row>.0.<col>
  columns: 4
  rows: 4
  metric: 10
  # base_router_id: 10.0.0.0    # then r1c1 is 10.1.0.1

routers:
  - name: edge
    id: 10.0.0.1
    loopback: 10.255.0.1
    networks: [172.16.10.0/24, { prefix: 172.16.20.0/24, metric: 20 }]
    summaries:
      - { prefix: 30.0.0.0/24, count: 25, metric: 10 }     # 25 consecutive /24s
    externals:
      - { prefix: 50.0.0.0/24, count: 100, metric: 20, type: 2, tag: 100 }
    asbr_summaries: [5.5.5.5]

links:
  - { from: r4c4, to: edge, metric: 5 }
  - [r1c1, r2c2, { state: down }]
```

A router with summaries is marked ABR, one with externals ASBR. Links are
point-to-point; each gets a /30 from `link_prefix`. `sim` names the simulated router.
Errors name the exact key, for example `routers[2].externals[0]: unknown key(s) typ`.

See `examples/grid.yml` for a complete file.

The same topology in Ruby:

```ruby
require 'ospfv2/simulator'

topo = OSPFv2::Topology.build do
  simulator router_id: '1.1.1.1', interface: '192.168.1.123/24'
  grid columns: 4, rows: 4, metric: 10
  router 'edge', id: '10.0.0.1' do
    loopback '10.255.0.1'
    externals '50.0.0.0/24', count: 100, metric: 20
  end
  link 'r4c4', 'edge', metric: 5
end

sim = OSPFv2::Simulator.new(topo).start
sim.link_down('r1c1--r1c2')
sim.flap('r2c2--r2c3', count: 5, interval: 10)
```

## Commands

| Command | What it does |
| --- | --- |
| `run FILE` | Bring up the adjacency. `--web [ADDR:]PORT`, `--console irb\|none`, `--log FILE` |
| `demo [FILE]` | Same, against a built-in peer on an in-memory segment |
| `show FILE` | Print the generated LSDB. `-f junos\|ios\|plain\|json`, `-t TYPE`, `-v` |
| `export FILE` | `-f dot` (Graphviz), `json` or `yaml` |
| `check FILE` | Validate and summarize |
| `init` | Print a starter topology. `--grid CxR`, `--interface ADDR/LEN` |

`run` also takes `-i ADDR/LEN`, `-r ID`, `-a AREA` and `--device DEV` to override
the file. The original flags still work: `ospfv2 -i 192.168.1.10/24 -g 3x3 -S 10 -E 20`.

### Console

```
ospf> state                 neighbor state, DUT, DR, LSA counts
ospf> links "r2"            links with id and state
ospf> down 3                take link 3 down (or down "r1c1--r1c2")
ospf> flap 3, count: 5, interval: 10
ospf> lsdb :ios             the LSDB, Cisco style
ospf> lsa :router, "0.1.0.1"
ospf> refresh               new sequence numbers for every simulated LSA
ospf> aging on
```

### Web dashboard and API

The dashboard listens on 127.0.0.1 unless you pass an address. The JSON API behind it:

| Method | Path | |
| --- | --- | --- |
| GET | `/api/state` | neighbor, counts, graph, links |
| GET | `/api/lsdb` | LSA rows; `/api/lsdb.txt?format=junos\|ios&verbose=1` for text |
| GET | `/api/lsa?type=router&id=0.1.0.1&advr=0.1.0.1` | one LSA, verbose |
| GET | `/api/events?since=N` | events after sequence N |
| POST | `/api/links/:id/up\|down\|toggle\|flap` | flap takes `{"count":3,"interval":5}` |
| POST | `/api/refresh`, `/api/flush`, `/api/aging` | aging takes `{"on":true}` |

POST requests need an `X-OSPFv2: 1` header. It stops other web pages from driving the
simulator through your browser.

## Router mode: ospfd and ospf-cli

`ospfd` runs OSPFv2 on the host's interfaces. It forms adjacencies
(broadcast with DR/BDR election, point-to-point, passive), keeps the database in sync,
originates router and network LSAs, authenticates packets, and computes the routing
table: intra-area, inter-area and external type 1 and 2 routes, with equal-cost
multipath. SPF runs with the RFC 8405 back-off (50 ms after a quiet spell, slower while
the network keeps changing). The routes go into the Linux routing table over netlink.

ospfd needs CAP_NET_RAW for OSPF packets and CAP_NET_ADMIN for routes (root has both).

```sh
sudo bin/ospfd -f /etc/ospfv2/ospfd.conf      # foreground; -l FILE to log to a file
sudo bin/ospf-cli                             # interactive
sudo bin/ospf-cli -c 'show ospf neighbor'     # one command
```

The management socket is `/run/ospfv2/ospfd.sock` (`-s` on both, or `OSPFV2_SOCKET`).
It is mode 0660: root, plus the group given with `ospfd -g GROUP`.

### Configuring

Configuration works like Junos: `configure`, then `set` and `delete` statements, then
`commit`. Every word can be cut to a unique prefix, Tab completes, and `?` lists what
can come next.

```
ospf> configure
ospf# set routing-options router-id 1.1.1.1
ospf# set protocols ospf area 0 interface eth1 interface-type p2p
ospf# set protocols ospf area 0 interface eth1 authentication md5 1 key "secret"
ospf# set protocols ospf area 0 interface lo passive
ospf# show | compare
ospf# commit
ospf# exit
```

| Statement under `protocols ospf area A interface IF` | Default |
| --- | --- |
| `interface-type broadcast\|p2p` | broadcast |
| `metric 1..65535` | 10 |
| `priority 0..255` | 1 |
| `hello-interval`, `dead-interval`, `retransmit-interval`, `transit-delay` (seconds) | 10, 4 x hello, 5, 1 |
| `mtu 576..65535`, `mtu-ignore` | 1500 |
| `passive` | off: advertise the subnet, no hellos |
| `disable` | off: keep the statements, do not run OSPF |
| `authentication simple-password PW` | none |
| `authentication md5\|hmac-sha-1\|hmac-sha-256\|hmac-sha-384\|hmac-sha-512 ID key SECRET` | none |
| `authentication send-key ID` | highest key id |

Several keys can be configured at once. Every one is accepted, the send key signs.
That is how keys roll over without dropping adjacencies.

`commit check` validates without applying, `compare` shows uncommitted changes,
`rollback N` loads one of the last 9 committed versions, `discard` drops changes.
Commit writes the file given with `-f` (mode 0600, as `set` lines) and keeps the
previous versions next to it as `ospfd.conf.rollback.N`. `kill -HUP` reloads the file.

### Areas and external routes

An interface in a second area makes ospfd an area border router: it sets the B bit and
tells each area about the others with summary-LSAs (and about AS boundary routers
with type 4 summaries), as RFC 2328 12.4.3 says.

A stub area takes no external routes; its area border routers send a default route
instead, and with `no-summaries` nothing else (totally stubby):

```
set protocols ospf area 1 stub
set protocols ospf area 2 stub default-metric 10 no-summaries
```

Every router in the area must agree, or they will not become neighbors. Changing it
restarts the area's interfaces.

External routes are advertised through an export policy, as on Junos. The host's own
networks (`direct`) and static routes in the kernel (`static`) are the sources.

```
set policy-options policy-statement EXPORT term lan from protocol direct
set policy-options policy-statement EXPORT term lan from route-filter 192.0.2.0/24 exact
set policy-options policy-statement EXPORT term lan then external type 1
set policy-options policy-statement EXPORT term lan then accept
set policy-options policy-statement EXPORT term statics from protocol static
set policy-options policy-statement EXPORT term statics then metric 50
set policy-options policy-statement EXPORT term statics then tag 100
set policy-options policy-statement EXPORT term statics then accept
set protocols ospf export EXPORT
```

Terms are tried in order. `route-filter` takes `exact` (the default), `orlonger`,
`longer` or `upto /N`. `then` sets `metric` (default 20), `external type 1|2`
(default 2) and `tag`, and `accept` or `reject` ends the policy. A route no term
accepts is not exported. New addresses and static routes are picked up within 5
seconds.

### Routes in the kernel

ospfd installs every OSPF route that goes through a gateway. Networks the host sits
on are already connected routes and are left alone. Equal-cost paths go in as one
multipath route.

| Statement under `routing-options kernel` | Default |
| --- | --- |
| `metric 1..4294967295` | 20: the kernel route metric, lower wins between routes to one prefix |
| `protocol 5..255` | 89: the protocol id on our routes (`ip route show proto 89`); ids other daemons use are refused |
| `table ID` | 254, the main table |
| `no-install` | off: compute routes, install none |

Only routes carrying our protocol id are ever read, changed or deleted, so routes from
FRR (188), static routes and DHCP are safe. A new route never overwrites another route
to the same prefix at the same metric: it is refused and reported instead. Changes to
our own routes go in as replace, so a route never disappears while it changes; deletes
go last. If the protocol id or table changes, or install is turned off, routes left
under the old settings (after a crash, say) are removed. A route the kernel refuses is retried
every 5 seconds and shown in `show route protocol ospf`. Every 60 seconds the kernel
is read back and any drift repaired, with a log line per repair.

On a clean stop the routes are withdrawn. After a crash they stay in the kernel; the
restarted ospfd keeps them until OSPF has converged (every interface up and past its
DR election, every adjacency Full, no route change for 10 seconds; 60 seconds at most,
longer while a database exchange is still running), then removes the
ones it no longer has, so traffic it forwards has no gap. Traffic back to the router
still drops while the neighbors rebuild their adjacencies: avoiding that needs graceful
restart, which is not implemented yet.

A metric or authentication change applies without touching adjacencies. Other changes
to an interface restart it. An interface that does not exist yet, is down or has no
IPv4 address waits, and starts within 5 seconds of appearing.

### Show commands

Junos forms print Junos style, IOS forms print IOS style.

| Junos | IOS |
| --- | --- |
| `show ospf neighbor [detail]` | `show ip ospf neighbor [detail]` |
| `show ospf interface [detail]` | `show ip ospf interface [brief]` |
| `show ospf database [router\|network\|netsummary\|asbrsummary\|external] [detail]` | `show ip ospf database [router\|network\|summary\|asbr-summary\|external]` |
| `show ospf overview` | `show ip ospf` |
| `show ospf route [detail]` (computed) | `show ip ospf route` (computed, FRR style) |
| `show route protocol ospf` (in the kernel) | `show ip route ospf` (in the kernel) |
| `show ospf log` (SPF runs) | `show ip ospf statistics` (SPF runs) |
| `show ospf events` | `show ip ospf events` |
| `show ospf statistics` (packets) | `show ip ospf traffic` |
| `clear ospf neighbor [ROUTER-ID]` | `clear ip ospf process` |
| `show configuration` | |

Pipes: `| match REGEX`, `| except REGEX`, `| count`, `| last N`, `| display json`,
`| display set` (configuration). `include` and `exclude` work as on IOS.

## Docker

```sh
docker build -t ospfv2 .
docker run --rm -p 8080:8080 ospfv2                    # the demo
docker run --rm --network host --cap-add NET_RAW \
  -v $PWD/lab.yml:/work/lab.yml ospfv2 run lab.yml --web 0.0.0.0:8080
```

`docker-compose.yml` has three setups:

* `docker compose up ospfv2` runs `./lab.yml` on the host network against a real router.
* `docker compose --profile lab up` runs the simulator and a second ospfv2 as the DUT on
  a bridge, over real raw sockets. Dashboards on :8080 and :8081.
* `docker compose --profile frr up` puts FRRouting ospfd in the DUT seat. Then
  `docker compose exec frr vtysh -c "show ip ospf database"`.

Containers drop every capability except `NET_RAW`.

## How it behaves

* The simulated router has priority 0. On a broadcast segment the DUT must be the DR.
  Updates and acks go to AllDRouters (224.0.0.6), as RFC 2328 13.3 asks of a DROther.
* Until the adjacency is Full, the simulated router advertises the segment as a stub.
  Once Full it advertises a transit link to the DR, or a point-to-point link to the DUT
  on a p2p network. Without that link back, the DUT would hold the LSAs but install no
  routes.
* Hellos with a different hello interval, dead interval, netmask or area are dropped
  and logged, the way a router would. So are packets with a bad checksum.
* Taking a link down removes the point-to-point entries from both router LSAs, keeps
  the stubs, bumps the sequence numbers and floods the new instances.

Supported: router, network, summary, ASBR summary, AS external and TE opaque LSAs;
hello, DD, LS request, LS update and LS ack packets; null authentication.
Not supported: MD5 or HMAC authentication, DR election by the simulator, NSSA, more
than one neighbor per process. RFC 2328 and RFC 4915 (multi-topology metrics).

## Development

```sh
bundle install
bundle exec rake test               # unit and integration tests
bundle exec rake test:integration   # two simulators syncing over an in-memory segment
docker build --target test .        # the same tests inside the image
```

`REVIEW.md` describes the code base, what changed in the 2026 refresh and what is
worth rewriting next.

## License

GPL-3.0-or-later. Copyright Jean-Michel Esnault.
