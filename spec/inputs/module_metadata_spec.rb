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
end
