require 'test/unit'
require 'tmpdir'
require 'ospfv2/topology'

class TestTopology < Test::Unit::TestCase
  include OSPFv2

  def load(yaml)
    Dir.mktmpdir do |d|
      f = File.join(d, 't.yml')
      File.write(f, yaml)
      Topology.load(f)
    end
  end

  def test_example_file
    t = Topology.load(File.expand_path('../../../examples/grid.yml', __dir__))
    assert_equal 19, t.counts[:routers]
    assert_equal 25, t.counts[:summaries]
    assert_equal 51, t.counts[:externals]
    assert_equal :down, t.links.find { |l| l.name == 'abr1--asbr1' }.state
  end

  def test_defaults
    t = load("routers: [{ name: a, id: 10.0.0.1 }]\n")
    s = t.settings
    assert_equal IPAddr.new('1.1.1.1').to_i, s.router_id
    assert_equal :broadcast, s.network_type
    assert_equal 10, s.hello_interval
    assert_equal [%w[sim a]], t.links.map { |l| [l.from, l.to] }, 'sim attaches to the first router'
  end

  def test_grid_names_ids_and_links
    t = Topology.from_hash(grid: { columns: 3, rows: 2, metric: 7 })
    assert_equal IPAddr.new('0.2.0.3').to_i, t.routers['r2c3'].id
    # 2 rows x 2 horizontal + 3 vertical + attach
    assert_equal 2 * 2 + 3 + 1, t.links.size
    assert_equal %w[sim r1c1], [t.links.last.from, t.links.last.to]
    assert t.links.first(7).all? { |l| l.metric == 7 }
  end

  def test_grid_base_router_id
    t = Topology.from_hash(grid: { columns: 1, rows: 1, base_router_id: '10.0.0.0' })
    assert_equal '10.1.0.1', t.routers['r1c1'].id_ip
  end

  def test_attach_none_and_explicit_sim_links
    t = Topology.from_hash(simulator: { attach_to: 'none' }, grid: { columns: 2, rows: 1 })
    assert t.links.none? { |l| l.from == 'sim' }
    t = Topology.from_hash(grid: { columns: 2, rows: 1 }, links: [%w[sim r1c2]])
    assert_equal 1, t.links.count { |l| l.from == 'sim' }
  end

  def test_expansion
    t = Topology.from_hash(routers: [{ id: '10.0.0.1', summaries: [{ prefix: '30.0.0.0/24', count: 3 }],
                                       externals: [{ prefix: '50.0.0.0/16', count: 2, type: 1, tag: 4 }] }])
    r = t.routers['10.0.0.1']
    assert_equal %w[30.0.0.0/24 30.0.1.0/24 30.0.2.0/24], r.summaries.map(&:prefix)
    assert_equal %w[50.0.0.0/16 50.1.0.0/16], r.externals.map(&:prefix)
    assert_equal [1, 4], [r.externals[0].type, r.externals[0].tag]
    assert r.abr && r.asbr, 'summaries imply ABR, externals imply ASBR'
  end

  def test_loopback_becomes_host_stub
    t = Topology.from_hash(routers: [{ id: '10.0.0.1', loopback: '10.255.0.1' }])
    assert_equal ['10.255.0.1/32'], t.routers['10.0.0.1'].networks.map(&:prefix)
  end

  def test_lookup_by_name_or_id
    t = Topology.from_hash(routers: [{ name: 'core', id: '10.0.0.1' }])
    assert_equal 'core', t.router('10.0.0.1').name
    assert_equal 'core', t.router('core').name
    assert_equal 'sim', t.router('1.1.1.1').name
    assert_nil t.router('nope')
  end

  def test_dsl
    t = Topology.build do
      simulator router_id: '9.9.9.9', interface: '10.1.1.2/30', network_type: 'p2p'
      grid columns: 2, rows: 2
      router 'edge', id: '10.0.0.1' do
        loopback '10.255.0.1'
        externals '50.0.0.0/24', count: 5
      end
      link 'r2c2', 'edge', metric: 3
    end
    assert_equal :p2p, t.settings.network_type
    assert_equal 5, t.routers['edge'].externals.size
    assert_equal 3, t.links.find { |l| l.to == 'edge' }.metric
  end

  def test_yaml_round_trip
    t = Topology.load(File.expand_path('../../../examples/grid.yml', __dir__))
    again = load(t.to_yaml)
    assert_equal t.counts, again.counts
    assert_equal t.links.map(&:to_h), again.links.map(&:to_h)
  end

  ERRORS = {
    "simulator: { interface: 10.0.0.1 }" => /needs a prefix length/,
    "simulator: { network_type: nbma }" => /broadcast or p2p/,
    "simulator: { hello_interval: 0 }" => /must be > 0/,
    "bogus: 1" => /unknown section/,
    "routers: [{ id: 10.0.0.1, color: red }]" => /unknown key\(s\) color/,
    "routers: [{ name: a }]" => /id is required/,
    "routers: [{ id: 1.1.1.1 }]" => /simulator's router id/,
    "routers: [{ id: 10.0.0.1 }, { id: 10.0.0.1, name: b }]" => /already used/,
    "routers: [{ id: 10.0.0.256 }]" => /not a router id/,
    "routers: [{ id: 1, externals: [{ prefix: 50.0.0.0/24, type: 3 }] }]" => /must be 1 or 2/,
    "routers: [{ id: 1, networks: [banana/24] }]" => /not a valid prefix/,
    "grid: { columns: 2, rows: 1 }\nlinks: [[r1c1, r1c2]]" => /duplicate link/,
    "links: [[a, b]]" => /unknown router "a"/,
    "routers: [{ id: 1, name: x }]\nlinks: [{ from: x, to: x }]" => /two different routers/,
    "routers: [{ id: 1, name: x }]\nlinks: [{ from: x, to: sim, metric: 70000 }]" => /0..65535/,
    "links: [ { from: a" => /did not find|expected/
  }.freeze

  def test_errors_name_the_problem
    ERRORS.each do |yaml, msg|
      e = assert_raise(Topology::Error, yaml) { load(yaml) }
      assert_match msg, e.message, yaml
    end
  end
end
