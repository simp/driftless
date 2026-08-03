require 'spec_helper'

require 'driftless/detectors/hierarchy_unreachable_data_files'
require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/inputs/hierarchy_loader'

RSpec.describe Driftless::Detectors::HierarchyUnreachableDataFiles do
  def fixture(name)
    File.expand_path("../fixtures/control_repos/#{name}", __dir__)
  end

  def corpus_for(fixture_name)
    tiers, _ = Driftless::Inputs::HierarchyLoader.load(fixture(fixture_name))
    Driftless::Corpus.new(
      repo: nil, hiera_tiers: tiers, puppet_classes: {},
      data_files: [], reported: Driftless::Reported.new(data: {}),
      lookup_calls: [], log: nil,
    )
  end

  describe '#call' do
    context 'against the unreachable_paths fixture' do
      let(:findings) { described_class.new(corpus_for('unreachable_paths')).call }

      it 'flags files whose path no tier template pattern could match' do
        misc_path = File.join(fixture('unreachable_paths'), 'data/random_dir/misc.yaml')
        expect(findings.map(&:path)).to include(misc_path)
      end

      it 'does NOT flag files that match a tier template pattern (fact-independent, so ghost hosts survive)' do
        web1_path    = File.join(fixture('unreachable_paths'), 'data/hosts/web1.yaml')
        default_path = File.join(fixture('unreachable_paths'), 'data/default.yaml')
        expect(findings.map(&:path)).not_to include(web1_path, default_path)
      end
    end

    context 'against the orphans fixture where every file structurally matches a tier' do
      # orphans/ has hosts/{web1,ghost}.example.com.yaml + os/family/{RedHat,Debian}.yaml + default.yaml,
      # and its tier patterns are hosts/*, os/family/*, default.yaml — all files match.
      # ghost.example.com.yaml is fact-orphan but NOT structurally unreachable — that is
      # hierarchy:orphaned-paths' concern, not this detector's.
      let(:findings) { described_class.new(corpus_for('orphans')).call }

      it 'emits nothing (every file matches some tier pattern; ghost hosts are not this detector\'s concern)' do
        expect(findings).to be_empty
      end
    end

    context 'requires no reports (purely static check)' do
      it 'has an empty requires_reports declaration, so cannot be skipped by missing reports' do
        expect(described_class.requires_reports).to be_empty
      end
    end
  end
end
