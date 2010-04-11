require 'rubygems'
Gem::Specification.new do |spec|
  spec.name         = "ospfv2"
  spec.version      = "0.0.1"
  spec.author       = "Jean Michel Esnault"
  spec.email        = "jme@spidercloud.com"
  spec.summary      = "An OSPFv2 Emulator."
  spec.files        =  Dir['lib/**/*.rb']
  spec.require_paths << 'lib'
  spec.has_rdoc     = false
  spec.executables << 'ospfv2'
end
