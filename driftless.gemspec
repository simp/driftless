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

  spec.files         = Dir['lib/**/*.rb', 'lib/driftless/site/templates/*', 'bin/*']
  spec.bindir        = 'bin'
  spec.executables   = ['driftless']
  spec.require_paths = ['lib']

  # Puppet/OpenVox is deliberately NOT a runtime dependency. On an openvox-agent
  # host it lives in vendor_ruby (not a gem), and the AIO's gemspec stub is named
  # puppet-*.gemspec while declaring name "openvox", so RubyGems cannot resolve
  # it by name. Treat it as provided by the host; see Gemfile for dev/test.
  spec.add_runtime_dependency 'deep_merge', '~> 1.2'
end
