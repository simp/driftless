require 'spec_helper'
require 'tmpdir'

require 'driftless/inputs/hierarchy_loader'

RSpec.describe Driftless::Inputs::HierarchyLoader do
  def fixture(name)
    File.expand_path("../fixtures/control_repos/#{name}", __dir__)
  end

  describe '.load' do
    context 'with a minimal well-formed hiera.yaml (3 tiers, all yaml_data)' do
      let(:result)   { described_class.load(fixture('minimal')) }
      let(:tiers)    { result[0] }
      let(:findings) { result[1] }

      it 'returns three tiers and no findings' do
        expect(tiers.size).to eq(3)
        expect(findings).to be_empty
      end

      it 'normalizes datadir to an absolute path under the repo' do
        tiers.each do |t|
          expect(t.datadir).to eq(File.join(fixture('minimal'), 'data'))
        end
      end

      it 'defaults every tier backend to yaml_data' do
        expect(tiers).to all(have_attributes(backend: :yaml_data))
      end

      it 'preserves path templates verbatim' do
        by_name = tiers.each_with_object({}) { |t, h| h[t.name] = t }
        expect(by_name['Per-host'].path_templates).to eq(['hosts/%{trusted.certname}.yaml'])
        expect(by_name['Default'].path_templates).to eq(['default.yaml'])
      end

      it 'extracts interpolation vars per tier' do
        by_name = tiers.each_with_object({}) { |t, h| h[t.name] = t }
        expect(by_name['Per-host'].interpolation_vars).to include('trusted.certname')
        expect(by_name['OS family'].interpolation_vars).to include('facts.os.family')
        expect(by_name['Default'].interpolation_vars).to eq([])
      end

      it 'marks every single-path tier as multi_path? false' do
        expect(tiers).to all(satisfy { |t| t.multi_path? == false })
      end
    end

    context 'with a multi-paths tier' do
      let(:result) { described_class.load(fixture('multi_paths_tier')) }
      let(:tiers)  { result[0] }

      it 'sets multi_path? true and preserves both templates in order' do
        multi = tiers.find(&:multi_path?)
        expect(multi).not_to be_nil
        expect(multi.path_templates).to eq([
          'os/family/%{facts.os.family}/%{facts.os.release.major}.yaml',
          'os/family/%{facts.os.family}.yaml',
        ])
      end

      it 'de-duplicates interpolation vars across templates' do
        multi = tiers.find(&:multi_path?)
        expect(multi.interpolation_vars).to contain_exactly(
          'facts.os.family',
          'facts.os.release.major',
        )
      end
    end

    context 'with an unsupported lookup_key backend tier' do
      let(:result)   { described_class.load(fixture('unsupported_backend')) }
      let(:tiers)    { result[0] }
      let(:findings) { result[1] }

      it 'skips the unsupported tier but keeps the others' do
        expect(tiers.map(&:name)).to eq(['Default'])
      end

      it 'emits one hierarchy:unsupported-backend finding' do
        expect(findings.map(&:key)).to eq(['hierarchy:unsupported-backend'])
      end
    end

    context 'with no hiera.yaml at all' do
      it 'returns no tiers and a hierarchy:hiera-yaml-missing finding' do
        Dir.mktmpdir do |empty|
          tiers, findings = described_class.load(empty)
          expect(tiers).to be_empty
          expect(findings.map(&:key)).to eq(['hierarchy:hiera-yaml-missing'])
        end
      end
    end

    context 'with malformed YAML' do
      it 'returns no tiers and a data:yaml-parse-error finding' do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, 'hiera.yaml'), "{{ bad: yaml : : - -\n  more")
          tiers, findings = described_class.load(dir)
          expect(tiers).to be_empty
          expect(findings.map(&:key)).to eq(['data:yaml-parse-error'])
        end
      end
    end
  end
end
