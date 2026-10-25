# ospfv2

Simulate an OSPFv2 area behind a single adjacency.

`ospfv2` brings up an OSPF neighbor with a router under test (the DUT) and floods a
synthetic link state database behind it. Use it to load a router with thousands of
LSAs, flap links and watch SPF, or check how a router handles summaries and externals.

It targets Ruby 3.1 and later (CI covers 3.2 to 4.0), uses the standard library only,
and ships as a Docker image.

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
