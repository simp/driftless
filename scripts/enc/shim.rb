#!/opt/puppetlabs/puppet/bin/ruby
# An ENC that answers top-scope variables from the environment's Hiera
# hierarchy, looked up in order so that each answer is in scope for the
# next. No node, no compiler, no facts: Hiera reads the variables from a
# scope shim. Usage: shim.rb CERTNAME [ENVIRONMENT]
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
require 'puppet'
require 'yaml'
loaded = Process.clock_gettime(Process::CLOCK_MONOTONIC)

certname = ARGV[0] || 'n1.example.com'
VARIABLES = %w[tenant site role].freeze # site.pp's assignment order

Puppet.initialize_settings(['--environmentpath', File.join(__dir__, 'env'), '--strict_variables', '--strict=error'])
env = Puppet.lookup(:environments).get!(ARGV[1] || 'production')

# Hiera uses a scope's:
# - environment
# - loaders (to load the backend functions)
# - `compiler` (the lookup adapter attaches there)
# - variable
# In this shim, unknown variables return nil, which Hiera interpolates
# as '', so Puppet's strict settings don't apply here.
class ScopeShim
  attr_reader :environment, :loaders

  def initialize(environment, loaders, vars)
    @environment = environment
    @loaders = loaders
    @vars = vars
  end

  def compiler = self
  def exist?(name) = @vars.key?(name.delete_prefix('::'))
  def lookupvar(name, _options = {}) = @vars[name.delete_prefix('::')]
  def [](name) = lookupvar(name)

  def []=(name, value)
    @vars[name] = value
  end

  def method_missing(name, *args)
    warn "shim: Hiera called #{name}(#{args.map(&:inspect).join(', ')})"
    super
  end

  def respond_to_missing?(*) = false
end

loaders = Puppet::Pops::Loaders.new(env)
scope = ScopeShim.new(env, loaders, { 'trusted' => { 'certname' => certname } })
params = {}
Puppet.override(current_environment: env, loaders: loaders) do
  VARIABLES.each do |key|
    params[key] = Puppet::Pops::Lookup.lookup(key, nil, nil, false, nil, Puppet::Pops::Lookup::Invocation.new(scope))
    scope[key] = params[key]
  end
end
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts({ 'parameters' => params, 'classes' => {} }.to_yaml)
warn 'require %.2fs, lookups %.2fs' % [loaded - t0, t1 - loaded]
