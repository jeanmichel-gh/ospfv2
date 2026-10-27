# frozen_string_literal: true

require_relative 'lib/ospfv2/version'

Gem::Specification.new do |spec|
  spec.name          = 'ospfv2'
  spec.version       = OSPFv2::VERSION
  spec.authors       = ['Jean-Michel Esnault']
  spec.email         = ['ospfv2@esnault.org']
  spec.summary       = 'OSPFv2 router and topology simulator written in Ruby.'
  spec.description   = <<~DESC
    Brings up an OSPFv2 adjacency with a router under test and floods a
    synthetic link state database behind it: grids of routers, stub
    networks, summary, ASBR summary, AS external and TE opaque LSAs.
    Topologies are described in YAML or Ruby and can be driven live
    from an interactive console or a small web dashboard.
    ospfd is a full OSPFv2 router: areas, stub and NSSA, virtual links,
    SPF, routes in the Linux kernel, configured in Junos style.
  DESC
  spec.homepage      = 'https://github.com/jeanmichel-gh/ospfv2'
  spec.license       = 'GPL-3.0-or-later'
  spec.required_ruby_version = '>= 3.1'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri']   = "#{spec.homepage}/blob/master/changelog.txt"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*', 'bin/*', 'examples/**/*', 'LICENSE.txt', 'COPYING', 'README.md', 'changelog.txt']
  spec.bindir        = 'bin'
  spec.executables   = %w[ospfv2 ospfd ospf-cli]
  spec.require_paths = ['lib']
  spec.extra_rdoc_files = ['LICENSE.txt', 'README.md']

  # irb is a bundled gem from Ruby 3.5/4.0 on, so declare it for the console.
  spec.add_dependency 'irb', '>= 1.6'
  # Line editing for ospf-cli. Default gem up to Ruby 3.4, bundled after.
  spec.add_dependency 'reline', '>= 0.3'
end
