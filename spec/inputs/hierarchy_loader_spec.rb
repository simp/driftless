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

      it 'records each path template line in template_lines' do
        by_name = tiers.each_with_object({}) { |t, h| h[t.name] = t }
        expect(by_name['Per-host'].template_lines).to eq('hosts/%{trusted.certname}.yaml' => 8)
        expect(by_name['Default'].template_lines).to eq('default.yaml' => 12)
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

      it 'records a line per template' do
        multi = tiers.find(&:multi_path?)
        expect(multi.template_lines).to eq(
          'os/family/%{facts.os.family}/%{facts.os.release.major}.yaml' => 9,
          'os/family/%{facts.os.family}.yaml' => 10,
        )
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

      it 'emits one hierarchy:unscannable-by-driftless-backend finding' do
        expect(findings.map(&:key)).to eq(['hierarchy:unscannable-by-driftless-backend'])
      end
    end

    context 'with tiers driftless cannot locate data for' do
      let(:result)   { described_class.load(fixture('unscanned_locator')) }
      let(:tiers)    { result[0] }
      let(:findings) { result[1] }

      it 'skips them but keeps the others' do
        expect(tiers.map(&:name)).to eq(['Default'])
      end

      it 'reports each as hierarchy:tier-missing-path' do
        expect(findings.map(&:key)).to eq(%w[hierarchy:tier-missing-path hierarchy:tier-missing-path])
      end

      it 'names an unscanned locator rather than blaming the config' do
        expect(findings[0].message).to eq('tier "Roles" uses mapped_paths:, a locator driftless does not scan')
      end

      it 'lists the scanned locators when a tier declares none' do
        expect(findings[1].message).to eq('tier "No locator" declares no path:, paths:, glob:, or globs:')
      end
    end

    context 'with glob: and globs: tiers' do
      let(:result) { described_class.load(fixture('glob_tier')) }
      let(:tiers)  { result[0] }
      let(:by_name) { tiers.each_with_object({}) { |t, h| h[t.name] = t } }

      it 'keeps them instead of reporting hierarchy:tier-missing-path' do
        expect(result[1].map(&:key)).not_to include('hierarchy:tier-missing-path')
        expect(tiers.map(&:name)).to eq(['Globbed per-host', 'Globbed OS', 'Default'])
      end

      it 'records the locator so a glob is not mistaken for a path' do
        expect(by_name['Globbed per-host'].locator).to eq(:glob)
        expect(by_name['Globbed OS'].locator).to eq(:glob)
        expect(by_name['Default'].locator).to eq(:path)
      end

      it 'answers glob? per tier' do
        expect(by_name['Globbed per-host']).to be_glob
        expect(by_name['Default']).not_to be_glob
      end

      it 'treats globs: as a sub-hierarchy, like paths:' do
        expect(by_name['Globbed OS']).to be_multi_path
        expect(by_name['Globbed OS'].path_templates)
          .to eq(['os/%{facts.os.family}.yaml', 'os/shared-*.yaml'])
      end

      it 'extracts interpolation vars from a glob like any other template' do
        expect(by_name['Globbed per-host'].interpolation_vars).to eq(['trusted.certname'])
        expect(by_name['Globbed OS'].interpolation_vars).to eq(['facts.os.family'])
      end

      # Hiera permits one location key per tier and checks them in this order,
      # so the first present is the one it would use.
      it 'prefers path: over glob: when a tier declares both' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'data'))
          File.write(File.join(dir, 'hiera.yaml'), <<~YAML)
            ---
            version: 5
            hierarchy:
              - name: 'Both'
                path: 'common.yaml'
                glob: '*.yaml'
          YAML
          tiers, = described_class.load(dir)
          expect(tiers.first.locator).to eq(:path)
          expect(tiers.first.path_templates).to eq(['common.yaml'])
        end
      end
    end

    context 'with a datadir that is not a directory' do
      # Nothing else notices: every consumer does Dir[File.join(datadir, ...)],
      # which returns [] for a directory that is not there.
      def repo(dir, hiera)
        File.write(File.join(dir, 'hiera.yaml'), hiera)
        described_class.load(dir)
      end

      let(:one_bad_tier) do
        <<~YAML
          ---
          version: 5
          hierarchy:
            - name: 'Typo'
              datadir: dat
              path: 'common.yaml'
            - name: 'Fine'
              datadir: data
              path: 'default.yaml'
        YAML
      end

      it 'emits one hierarchy:missing-datadir finding for the offending tier' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'data'))
          _tiers, findings = repo(dir, one_bad_tier)
          expect(findings.map(&:key)).to eq(['hierarchy:missing-datadir'])
        end
      end

      it 'names the datadir as hiera.yaml spells it, not the expanded path' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'data'))
          _tiers, findings = repo(dir, one_bad_tier)
          expect(findings.first.message).to include('"dat"')
          expect(findings.first.message).not_to include(dir)
        end
      end

      it 'anchors the finding to the tier line in hiera.yaml' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'data'))
          _tiers, findings = repo(dir, one_bad_tier)
          expect(findings.first.path).to eq(File.join(dir, 'hiera.yaml'))
          expect(findings.first.line).to eq(4)
        end
      end

      # The tier is declared correctly, so it stays in the hierarchy; only its
      # data files are missing.
      it 'still returns the tier' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'data'))
          tiers, _findings = repo(dir, one_bad_tier)
          expect(tiers.map(&:name)).to eq(%w[Typo Fine])
        end
      end

      # A typo in defaults: blinds every tier, so every tier reports it.
      it 'fires once per tier when the typo is in defaults' do
        Dir.mktmpdir do |dir|
          _tiers, findings = repo(dir, <<~YAML)
            ---
            version: 5
            defaults:
              datadir: dat
            hierarchy:
              - name: 'One'
                path: 'common.yaml'
              - name: 'Two'
                path: 'default.yaml'
          YAML
          expect(findings.map(&:key)).to eq(['hierarchy:missing-datadir'] * 2)
        end
      end

      # Hiera's own default when hiera.yaml declares no datadir at any level.
      it "catches the implicit 'data' datadir" do
        Dir.mktmpdir do |dir|
          _tiers, findings = repo(dir, <<~YAML)
            ---
            version: 5
            hierarchy:
              - name: 'Common'
                path: 'common.yaml'
          YAML
          expect(findings.map(&:key)).to eq(['hierarchy:missing-datadir'])
          expect(findings.first.message).to include('"data"')
        end
      end

      # Hiera renders datadir before resolving paths against it (Puppet's
      # HieraConfigV5), so a token here is a legitimate hierarchy and the
      # literal string is never a directory.
      context 'when the datadir interpolates' do
        let(:interpolated) do
          <<~YAML
            ---
            version: 5
            hierarchy:
              - name: 'Interpolated'
                datadir: 'data/%{facts.os.family}'
                path: 'common.yaml'
          YAML
        end

        it 'reports hierarchy:interpolated-datadir, not missing-datadir' do
          Dir.mktmpdir do |dir|
            _tiers, findings = repo(dir, interpolated)
            expect(findings.map(&:key)).to eq(['hierarchy:interpolated-datadir'])
          end
        end

        it 'reports it even when the literal directory happens to exist' do
          Dir.mktmpdir do |dir|
            FileUtils.mkdir_p(File.join(dir, 'data/%{facts.os.family}'))
            _tiers, findings = repo(dir, interpolated)
            expect(findings.map(&:key)).to eq(['hierarchy:interpolated-datadir'])
          end
        end

        it 'still returns the tier' do
          Dir.mktmpdir do |dir|
            tiers, _findings = repo(dir, interpolated)
            expect(tiers.map(&:name)).to eq(['Interpolated'])
          end
        end
      end

      it 'stays quiet when the datadir exists' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'data'))
          _tiers, findings = repo(dir, <<~YAML)
            ---
            version: 5
            hierarchy:
              - name: 'Fine'
                path: 'common.yaml'
          YAML
          expect(findings).to be_empty
        end
      end

      # A tier driftless skips never reaches the datadir check.
      it 'does not report a datadir for a tier it already skipped' do
        Dir.mktmpdir do |dir|
          _tiers, findings = repo(dir, <<~YAML)
            ---
            version: 5
            hierarchy:
              - name: 'Vault'
                datadir: dat
                lookup_key: vault_lookup_key
          YAML
          expect(findings.map(&:key)).to eq(['hierarchy:unscannable-by-driftless-backend'])
        end
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
