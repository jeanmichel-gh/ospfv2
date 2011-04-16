require 'rubygems'
Gem::Specification.new do |spec|
  spec.name         = "ospfv2"
  spec.version      = "0.0.2"
  spec.author       = "Jean Michel Esnault"
  spec.email        = "ospfv2@esnault.org"
  spec.summary      = "An OSPFv2 Emulator."
  spec.files        =  Dir['lib/**/*.rb']
  spec.files        << 'changelog.txt'
  spec.require_paths << 'lib'
  spec.executables << 'ospfv2'
end
