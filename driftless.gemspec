require_relative 'lib/driftless/version'

Gem::Specification.new do |spec|
  spec.name        = 'driftless'
  spec.version     = Driftless::VERSION
  spec.authors     = ['Chris Tessmer']
  spec.email       = ['chris.tessmer@onyxpoint.com']
  spec.summary     = 'Puppet/OpenVox control-repo infrastructure linter'
  spec.description = <<~DESC
    Cross-references what a Puppet/OpenVox control repo declares (Hiera
    hierarchy and data, manifests, modules) against what PuppetDB reports
    exists (active nodes, classified classes, factsets), and emits findings
    for stale, wrong, weird, or impossible configurations. Not a code linter
    (that is puppet-lint); not a catalog compiler (that is onceover).
  DESC
  spec.license     = 'Apache-2.0'
  spec.required_ruby_version = ['>= 3.2', '< 4.0']

  spec.files         = Dir['lib/**/*.rb', 'bin/*']
  spec.bindir        = 'bin'
  spec.executables   = ['driftless']
  spec.require_paths = ['lib']

  spec.add_runtime_dependency 'openvox',    '~> 8.28'
  spec.add_runtime_dependency 'deep_merge', '~> 1.2'

  spec.add_development_dependency 'rspec',     '~> 3.12'
  spec.add_development_dependency 'rspec-its', '~> 1.3'
end
