#!/opt/puppetlabs/puppet/bin/ruby
# The same ENC through Puppet's own scope: a Node, a Parser::Compiler with
# an empty program in place of the manifest, and its top scope. This is the
# path `puppet lookup` and pupgrade's `catalog lookup` take.
# Usage: compiler.rb CERTNAME [ENVIRONMENT]
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
require 'puppet'
require 'yaml'
loaded = Process.clock_gettime(Process::CLOCK_MONOTONIC)

certname = ARGV[0] || 'n1.example.com'
VARIABLES = %w[tenant site role].freeze # site.pp's assignment order

# strict_variables off here: a real Scope throws on an unset variable, and
# Hiera turns that into an "Interpolation failed" warning per lookup.
Puppet.initialize_settings(['--environmentpath', File.join(__dir__, 'env'), '--no-strict_variables', '--strict=error'])
env  = Puppet.lookup(:environments).get!(ARGV[1] || 'production')
node = Puppet::Node.new(certname, environment: env)
node.trusted_data = { 'certname' => certname, 'authenticated' => 'remote', 'extensions' => {} }

params = {}
Puppet.override(current_environment: env) do
  Puppet[:code] = 'undef' # stands in for the manifest, which is not evaluated
  compiler = Puppet::Parser::Compiler.new(node)
  compiler.compile do |catalog|
    scope = compiler.topscope
    VARIABLES.each do |key|
      params[key] = scope.call_function('lookup', [key])
      scope[key] = params[key]
    end
    catalog
  end
end
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts({ 'parameters' => params, 'classes' => {} }.to_yaml)
warn 'require %.2fs, lookups %.2fs' % [loaded - t0, t1 - loaded]
