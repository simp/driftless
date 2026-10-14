require 'spec_helper'
require 'tmpdir'
require 'json'

require 'driftless/inputs/module_metadata'

RSpec.describe Driftless::Inputs::ModuleMetadata do
  def with_metadata(contents)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'metadata.json'), contents) if contents
      yield described_class.load(dir)
    end
  end

  it 'reports exists? false when there is no metadata.json' do
    with_metadata(nil) do |result|
      expect(result.exists?).to be false
      expect([result.name, result.version, result.error, result.puppet_requirement]).to all(be_nil)
      expect(result.requirements).to eq({})
    end
  end

  it 'reads the name, version, and requirements' do
    contents = JSON.generate(
      'name' => 'puppetlabs-stdlib', 'version' => '9.0.0',
      'requirements' => [{ 'name' => 'puppet', 'version_requirement' => '>= 7.0.0 < 9.0.0' }],
    )
    with_metadata(contents) do |result|
      expect(result.exists?).to be true
      expect(result.name).to eq('puppetlabs-stdlib')
      expect(result.version).to eq('9.0.0')
      expect(result.requirements).to eq('puppet' => '>= 7.0.0 < 9.0.0')
      expect(result.puppet_requirement).to eq('>= 7.0.0 < 9.0.0')
    end
  end

  it 'reads openvox as the runtime requirement, joined with puppet when they differ' do
    with_metadata(JSON.generate('requirements' => [{ 'name' => 'openvox', 'version_requirement' => '>= 8.0.0' }])) do |result|
      expect(result.puppet_requirement).to eq('>= 8.0.0')
    end
    both = [{ 'name' => 'puppet', 'version_requirement' => '>= 7.0.0' }, { 'name' => 'openvox', 'version_requirement' => '>= 8.0.0' }]
    with_metadata(JSON.generate('requirements' => both)) do |result|
      expect(result.puppet_requirement).to eq('>= 7.0.0 / >= 8.0.0')
    end
    with_metadata(JSON.generate('requirements' => both.map { |r| r.merge('version_requirement' => '>= 8.0.0') })) do |result|
      expect(result.puppet_requirement).to eq('>= 8.0.0')
    end
  end

  it 'records an error for a file that is not a JSON mapping' do
    with_metadata('[1, 2]') do |result|
      expect(result.exists?).to be true
      expect(result.error).to include('metadata.json: not a mapping')
      expect(result.name).to be_nil
    end
    with_metadata('{') do |result|
      expect(result.error).to include('metadata.json: ')
    end
  end

  describe 'dependencies and operating systems' do
    def parse(data)
      described_class.parse(JSON.generate(data), path: 'x/metadata.json')
    end

    it 'reads dependencies as name => requirement, nil when none is given' do
      result = parse('dependencies' => [{ 'name' => 'puppetlabs/stdlib', 'version_requirement' => '>= 4.0.0' }, { 'name' => 'org-bare' }, 'junk'])
      expect(result.dependencies).to eq('puppetlabs/stdlib' => '>= 4.0.0', 'org-bare' => nil)
    end

    it 'reads operatingsystem_support as os => releases' do
      result = parse('operatingsystem_support' => [{ 'operatingsystem' => 'RedHat', 'operatingsystemrelease' => [8, '9'] },
                                                   { 'operatingsystem' => 'Debian' }])
      expect(result.operatingsystem_support).to eq('RedHat' => %w[8 9], 'Debian' => [])
    end

    it 'builds an absent result with no fields' do
      absent = described_class.absent
      expect(absent.exists?).to be false
      expect([absent.requirements, absent.dependencies, absent.operatingsystem_support]).to all(eq({}))
      expect(absent.with(name: 'x').name).to eq('x')
    end
  end
end
