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

    context 'source_line population' do
      let(:result) { described_class.load(fixture('minimal')) }
      let(:tiers)  { result[0] }

      it 'sets 1-indexed source_line per tier from hiera.yaml position' do
        # minimal/hiera.yaml: Per-host at line 7, OS family at line 9, Default at line 11
        by_name = tiers.each_with_object({}) { |t, h| h[t.name] = t }
        expect(by_name['Per-host'].source_line).to eq(7)
        expect(by_name['OS family'].source_line).to eq(9)
        expect(by_name['Default'].source_line).to eq(11)
      end

      it 'leaves source_line nil when the AST walk cannot align (parse-only, no crash)' do
        Dir.mktmpdir do |dir|
          # Valid YAML but unusual: hierarchy is a scalar, not a sequence.
          # Loader emits no tiers (each_with_index over Array(nil) → no iteration);
          # what we're asserting is that Psych parsing itself doesn't crash.
          File.write(File.join(dir, 'hiera.yaml'), "---\nversion: 5\nhierarchy: nope\n")
          expect { described_class.load(dir) }.not_to raise_error
        end
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

      it 'emits one hierarchy:unscannable-backend finding' do
        expect(findings.map(&:key)).to eq(['hierarchy:unscannable-backend'])
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
