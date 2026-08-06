require 'spec_helper'

require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/models/node'
require 'driftless/inputs/hierarchy_loader'
require 'driftless/detectors/hierarchy_paths_missing_reported_facts'

RSpec.describe Driftless::Detectors::HierarchyPathsMissingReportedFacts do
  def fixture(name)
    File.expand_path("../fixtures/control_repos/#{name}", __dir__)
  end

  def corpus_for(fixture_name, nodes: nil)
    tiers, _ = Driftless::Inputs::HierarchyLoader.load(fixture(fixture_name))
    data = nodes.nil? ? {} : { 'factsets-for-all-nodes' => nodes }
    Driftless::Corpus.new(
      repo_dir:       nil,
      hiera_tiers:    tiers,
      puppet_classes: {},
      data_files:     [],
      reported:       Driftless::Reported.new(data: data),
      code_lookup_calls:   [], data_lookup_calls: [],
      log:            nil,
    )
  end

  let(:web1) do
    Driftless::Node.new(
      certname: 'web1.example.com',
      facts:    { 'hostname' => 'web1', 'os' => { 'family' => 'RedHat' } },
      trusted:  { 'certname' => 'web1.example.com', 'hostname' => 'web1' },
    )
  end

  describe '#call' do
    context 'with no report:factsets-for-all-nodes data' do
      let(:findings) { described_class.new(corpus_for('orphans')).call }

      it 'emits exactly one skipped meta finding' do
        expect(findings.length).to eq(1)
      end

      it 'the skip finding is keyed skipped:hierarchy:paths-missing-reported-facts' do
        expect(findings.first.key).to eq('skipped:hierarchy:paths-missing-reported-facts')
      end
    end

    context 'against the orphans fixture with one node (web1 / RedHat)' do
      let(:findings) { described_class.new(corpus_for('orphans', nodes: [web1])).call }
      let(:orphans)  { findings.select { |f| f.key == 'hierarchy:paths-missing-reported-facts' } }

      it 'reports exactly the two files no tier resolves to' do
        expect(orphans.map(&:path)).to contain_exactly(
          File.join(fixture('orphans'), 'data/hosts/ghost.example.com.yaml'),
          File.join(fixture('orphans'), 'data/os/family/Debian.yaml'),
        )
      end

      it 'does NOT flag reachable files' do
        reachable_files = [
          File.join(fixture('orphans'), 'data/hosts/web1.example.com.yaml'),
          File.join(fixture('orphans'), 'data/os/family/RedHat.yaml'),
          File.join(fixture('orphans'), 'data/default.yaml'),
        ]
        expect(orphans.map(&:path)).not_to include(*reachable_files)
      end

      it 'emits no hierarchy:tier-unresolved (all tiers resolve for web1)' do
        expect(findings.map(&:key)).not_to include('hierarchy:tier-unresolved')
      end
    end

    context 'against the unresolvable_tier fixture with a node lacking that fact' do
      let(:findings) { described_class.new(corpus_for('unresolvable_tier', nodes: [web1])).call }

      it 'does NOT emit a meta finding for the unresolvable tier (disabled; low-priority informational)' do
        keys = findings.map(&:key)
        expect(keys).not_to include('hierarchy:tier-unresolved')
        expect(keys).not_to include('hierarchy:tiers-unmatched-to-reported-facts')
      end

      it 'does NOT flood-report the unresolvable tier\'s files (suppression still active)' do
        stig_path = File.join(fixture('unresolvable_tier'), 'data/compliance/stig.yaml')
        orphan_paths = findings.select { |f| f.key == 'hierarchy:paths-missing-reported-facts' }.map(&:path)
        expect(orphan_paths).not_to include(stig_path)
      end

      it 'still recognizes default.yaml as reachable via the static Default tier' do
        default_path = File.join(fixture('unresolvable_tier'), 'data/default.yaml')
        orphan_paths = findings.select { |f| f.key == 'hierarchy:paths-missing-reported-facts' }.map(&:path)
        expect(orphan_paths).not_to include(default_path)
      end
    end
  end
end
