require 'spec_helper'
require 'tmpdir'
require 'fileutils'

require 'driftless/inputs/module_data_loader'

RSpec.describe Driftless::Inputs::ModuleDataLoader do
  def module_with_data(root, name, hiera_yaml: true, data: {})
    dir = File.join(root, name)
    FileUtils.mkdir_p(File.join(dir, 'data'))
    if hiera_yaml
      File.write(File.join(dir, 'hiera.yaml'), <<~YAML)
        ---
        version: 5
        defaults:
          datadir: data
          data_hash: yaml_data
        hierarchy:
          - name: common
            path: common.yaml
      YAML
    end
    data.each { |file, body| File.write(File.join(dir, 'data', file), body) }
    dir
  end

  describe '.load' do
    it 'returns the keys in each module namespace from modules that have a hiera.yaml' do
      Dir.mktmpdir do |root|
        dirs = [
          module_with_data(root, 'baseline', data: {
            'common.yaml' => "baseline::profile::core::x: 1\nbaseline::y: 2\n",
          }),
          module_with_data(root, 'other', data: { 'common.yaml' => "other::z: 3\n" }),
        ]
        expect(described_class.load(dirs)).to eq(Set['baseline::profile::core::x', 'baseline::y', 'other::z'])
      end
    end

    it 'drops keys outside the module namespace' do
      Dir.mktmpdir do |root|
        dirs = [module_with_data(root, 'baseline', data: {
          'common.yaml' => "baseline::x: 1\nsomeone_else::y: 2\nlookup_options: {}\n",
        })]
        expect(described_class.load(dirs)).to eq(Set['baseline::x'])
      end
    end

    it 'ignores a module without a hiera.yaml even when data/ exists' do
      Dir.mktmpdir do |root|
        dirs = [module_with_data(root, 'nodata', hiera_yaml: false, data: { 'common.yaml' => "nodata::x: 1\n" })]
        expect(described_class.load(dirs)).to be_empty
      end
    end

    it 'returns an empty set for no modules' do
      expect(described_class.load([])).to eq(Set.new)
    end
  end
end
