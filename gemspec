
Gem::Specification.new do |spec|
  spec.name          = "ospfv2"
  spec.date          = "2014-10-17"
  spec.version       = "0.0.3"
  spec.author        = "Jean Michel Esnault"
  spec.email         = "ospfv2@esnault.org"
  spec.summary       = "Playing with OSPF version 2 using ruby."
  spec.description   = "Playing with OSPF version 2 using ruby."
  spec.homepage      =  "https://github.com/jesnault/ospfv2"
  spec.files         =  `git ls-files -z`.split("\x0")
  spec.rdoc_options  = ["--quiet", "--title", "ospfv2", "--line-numbers"]
  spec.require_paths = ["lib"]
  spec.bindir = 'bin'
  spec.executables   = ['ospfv2']
  spec.extra_rdoc_files = ["LICENSE.txt","README"]
end
