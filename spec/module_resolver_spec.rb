require 'spec_helper'
require 'json'

require 'driftless/module_resolver'

RSpec.describe Driftless::ModuleResolver do
  def entry(name, version: '1.0.0', deps: {}, puppet: nil, os: nil, path: nil)
    data = { 'name' => name, 'version' => version }
    data['dependencies'] = deps.map { |n, r| { 'name' => n, 'version_requirement' => r }.compact }
    data['requirements'] = [{ 'name' => 'puppet', 'version_requirement' => puppet }] if puppet
    data['operatingsystem_support'] = os.map { |o, rel| { 'operatingsystem' => o, 'operatingsystemrelease' => rel } } if os
    metadata = Driftless::Inputs::ModuleMetadata.parse(JSON.generate(data), path: "#{name}/metadata.json")
    Driftless::ModuleInventory::Entry.new(path: path || "modules/#{name.split(%r{[-/]}).last}", declared: nil,
                                          metadata: metadata, deployed: :unknown)
  end

  def resolve(entries, **opts)
    described_class.new(**opts).resolve(entries)
  end

  def keys(result)
    result.conflicts.map { |c| [c.kind, c.module, c.subject] }
  end

  it 'reports missing and out-of-range dependencies, matching names across - and /' do
    result = resolve([
      entry('puppetlabs-apache', deps: { 'puppetlabs/stdlib' => '>= 4.13.1 < 9.0.0', 'puppetlabs/concat' => '>= 2.2.1 < 8.0.0', 'org-any' => nil }),
      entry('puppetlabs-stdlib', version: '9.4.0'),
      entry('org-any'),
    ])
    expect(keys(result)).to eq([
      ['missing-dependency', 'puppetlabs-apache', 'puppetlabs/concat'],
      ['dependency-version', 'puppetlabs-apache', 'puppetlabs/stdlib'],
    ])
    expect(result.conflicts.map(&:detail)).to eq([
      'needs puppetlabs/concat >= 2.2.1 < 8.0.0; not on the modulepath',
      'needs puppetlabs/stdlib >= 4.13.1 < 9.0.0; modules/stdlib is 9.4.0',
    ])
    expect(result.warnings).to eq([])
  end

  it 'warns instead of comparing when a requirement or version does not parse' do
    result = resolve([
      entry('a', deps: { 'b' => 'banana', 'c' => '>= 1.0.0' }),
      entry('b'),
      entry('c', version: 'latest'),
    ])
    expect(result.conflicts).to eq([])
    expect(result.warnings).to eq([
      'a: dependency b: cannot parse version requirement "banana"',
      'c: version "latest" is not semantic; dependencies on it are not checked',
    ])
  end

  it 'reports Puppet requirements pairwise when no version satisfies every module' do
    agreeing = resolve([entry('a', puppet: '>= 7.0.0 < 9.0.0'), entry('b', puppet: '>= 8.0.0'), entry('c')])
    expect(agreeing.conflicts).to eq([])
    expect(agreeing.puppet_range).to eq('>=8.0.0 <9.0.0')

    split = resolve([
      entry('old', puppet: '>= 6.0.0 < 8.0.0'),
      entry('new', puppet: '>= 8.0.0'),
      entry('wide', puppet: '>= 7.0.0 < 9.0.0'),
    ])
    expect(keys(split)).to eq([%w[puppet-version new puppet], %w[puppet-version old puppet]])
    expect(split.conflicts.first.detail).to eq('requires puppet >= 8.0.0; no version in common with old (>= 6.0.0 < 8.0.0)')
    expect(split.puppet_range).to be_nil
  end

  it 'treats openvox as a puppet requirement' do
    result = resolve([
      entry('a', puppet: '>= 8.0.0'),
      Driftless::ModuleInventory::Entry.new(
        path: 'modules/b', declared: nil, deployed: :unknown,
        metadata: Driftless::Inputs::ModuleMetadata.parse(
          JSON.generate('name' => 'b', 'version' => '1.0.0', 'requirements' => [{ 'name' => 'openvox', 'version_requirement' => '< 8.0.0' }]),
          path: 'b',
        ),
      ),
    ])
    expect(keys(result)).to eq([%w[puppet-version a puppet], %w[puppet-version b puppet]])
  end

  it 'checks operating systems only when some are configured, and only on modules that declare any' do
    entries = [
      entry('a', os: { 'RedHat' => %w[7 8], 'Ubuntu' => [] }),
      entry('b', os: { 'redhat' => [] }),
      entry('c'),
    ]
    expect(resolve(entries).conflicts).to eq([])

    result = resolve(entries, operatingsystems: { 'RedHat' => ['8.4', 9], 'Ubuntu' => '22.04', 'Debian' => nil })
    expect(keys(result)).to eq([
      ['operatingsystem', 'a', 'Debian'],
      ['operatingsystem', 'a', 'RedHat 9'],
      ['operatingsystem', 'b', 'Debian'],
      ['operatingsystem', 'b', 'Ubuntu 22.04'],
    ])
    expect(result.conflicts.map(&:detail)).to eq([
      'declares no support for Debian (supports RedHat, Ubuntu)',
      'declares no support for RedHat 9 (supports RedHat 7, 8)',
      'declares no support for Debian (supports redhat)',
      'declares no support for Ubuntu (supports redhat)',
    ])
  end

  it 'drops conflicts matching the exclusion globs for their kind' do
    entries = [
      entry('a', deps: { 'missing' => nil }, puppet: '< 7.0.0', os: { 'Debian' => [] }),
      entry('b', puppet: '>= 8.0.0'),
    ]
    exclude = { 'dependencies' => ['A:MISS*'], 'requirements' => ['b'], 'operatingsystems' => ['redhat 9'] }
    result = resolve(entries, operatingsystems: { 'RedHat' => ['9'] }, exclude: exclude)
    expect(keys(result)).to eq([%w[puppet-version a puppet]])
    expect(result.excluded).to eq(3)
  end

  it 'ignores entries without a metadata name or with unreadable metadata' do
    nameless = Driftless::ModuleInventory::Entry.new(path: 'modules/x', declared: nil, deployed: :unknown,
                                                     metadata: Driftless::Inputs::ModuleMetadata.absent)
    broken   = Driftless::ModuleInventory::Entry.new(path: 'modules/y', declared: nil, deployed: :unknown,
                                                     metadata: Driftless::Inputs::ModuleMetadata.parse('{', path: 'y'))
    result = resolve([nameless, broken, entry('a', deps: { 'x' => nil })])
    expect(keys(result)).to eq([%w[missing-dependency a x]])
  end
end
