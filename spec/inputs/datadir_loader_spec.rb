require 'spec_helper'
require 'driftless/inputs/datadir_loader'
require 'driftless/models/hiera_tier'

RSpec.describe Driftless::Inputs::DatadirLoader do
  def fixture(name)
    File.expand_path("../fixtures/control_repos/#{name}", __dir__)
  end

  let(:datadir) { File.join(fixture('data_files'), 'data') }

  let(:tier) do
    Driftless::HieraTier.new(
      name:               'default',
      datadir:            datadir,
      backend:            :yaml_data,
      path_templates:     ['default.yaml'],
      interpolation_vars: [],
      multi_path:         false,
    )
  end

  describe '.load' do
    let(:result)     { described_class.load([tier]) }
    let(:data_files) { result[0] }
    let(:findings)   { result[1] }

    it 'loads all .yaml files under the tier datadir (recursive)' do
      rel_paths = data_files.map(&:path).map { |p| p.sub("#{datadir}/", '') }
      expect(rel_paths).to include('default.yaml', 'empty.yaml', 'list_root.yaml', 'nodes/web1.yaml')
    end

    it 'does NOT include the malformed file in data_files (it errored instead)' do
      rel_paths = data_files.map(&:path).map { |p| p.sub("#{datadir}/", '') }
      expect(rel_paths).not_to include('malformed.yaml')
    end

    it 'extracts top-level keys with 1-indexed line numbers from a hash-root file' do
      default_file = data_files.find { |df| df.path.end_with?('/default.yaml') }
      expect(default_file.top_level_keys).to eq(
        'profile::base::ensure'     => 2,
        'profile::firewall::enable' => 3,
        'namespace::only::key'      => 4,
      )
    end

    it 'primes value_lines with each scalar value and its line' do
      default_file = data_files.find { |df| df.path.end_with?('/default.yaml') }
      expect(default_file.value_lines).to eq([['present', 2], ['true', 3], ['value', 4]])
    end

    it 'traverses into nested subdirectories under the datadir' do
      web1 = data_files.find { |df| df.path.end_with?('/nodes/web1.yaml') }
      expect(web1).not_to be_nil
      expect(web1.top_level_keys.keys).to include(
        'profile::web::vhost',
        'profile::web::ssl',
        'role::web::extra_packages',
      )
    end

    it 'returns empty top_level_keys for a list-root YAML file' do
      lr = data_files.find { |df| df.path.end_with?('/list_root.yaml') }
      expect(lr.top_level_keys).to eq({})
    end

    it 'returns empty top_level_keys for an empty file' do
      empty = data_files.find { |df| df.path.end_with?('/empty.yaml') }
      expect(empty.top_level_keys).to eq({})
    end

    it 'emits a data:yaml-parse-error finding for the malformed file' do
      malformed_findings = findings.select { |f| f.key == 'data:yaml-parse-error' && f.path.end_with?('/malformed.yaml') }
      expect(malformed_findings.length).to eq(1)
    end

    it 'skips tiers whose backend is not yaml_data' do
      json_tier = Driftless::HieraTier.new(
        name: 'json', datadir: datadir, backend: :json_data,
        path_templates: [], interpolation_vars: [], multi_path: false,
      )
      dfs, = described_class.load([json_tier])
      expect(dfs).to be_empty
    end

    it 'de-duplicates files across tiers that share a datadir' do
      dup_tier = Driftless::HieraTier.new(
        name: 'dup', datadir: datadir, backend: :yaml_data,
        path_templates: [], interpolation_vars: [], multi_path: false,
      )
      dfs, = described_class.load([tier, dup_tier])
      paths = dfs.map(&:path)
      expect(paths.uniq).to eq(paths)
    end
  end
end
