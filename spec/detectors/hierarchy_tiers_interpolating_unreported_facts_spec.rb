require 'spec_helper'

require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/models/node'
require 'driftless/inputs/hierarchy_loader'
require 'driftless/detectors/hierarchy_tiers_interpolating_unreported_facts'

RSpec.describe Driftless::Detectors::HierarchyTiersInterpolatingUnreportedFacts do
  def fixture(name)
    File.expand_path("../fixtures/control_repos/#{name}", __dir__)
  end

  def corpus_for(fixture_name, nodes: nil)
    tiers, _ = Driftless::Inputs::HierarchyLoader.load(fixture(fixture_name))
    data = nodes.nil? ? {} : { 'factsets-for-all-active-nodes' => nodes }
    Driftless::Corpus.new(
      repo_dir:       fixture(fixture_name),
      hiera_tiers:    tiers,
      puppet_classes: {},
      data_files:     [],
      reported:       Driftless::Reported.new(data: data),
      code_lookup_calls: [], data_lookup_calls: [],
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
    context 'with no report:factsets-for-all-active-nodes data' do
      let(:findings) { described_class.new(corpus_for('unresolvable_tier')).call }

      it 'emits exactly one skipped meta finding, keyed with the "skipped:" prefix' do
        expect(findings.length).to eq(1)
        expect(findings.first.key).to eq('skipped:hierarchy:tiers-interpolating-unreported-facts')
      end
    end

    context 'against unresolvable_tier with web1 (which lacks the compliance_profile fact)' do
      let(:findings) { described_class.new(corpus_for('unresolvable_tier', nodes: [web1])).call }

      it 'emits exactly one finding, for the Compliance profile tier' do
        expect(findings.length).to eq(1)
        expect(findings.first.key).to eq('hierarchy:tiers-interpolating-unreported-facts')
      end

      it 'names both the tier and the unreported fact in the message' do
        expect(findings.first.message).to include('Compliance profile')
        expect(findings.first.message).to include('compliance_profile')
      end

      it 'attaches the finding to hiera.yaml with the tier\'s source_line' do
        f = findings.first
        expect(f.path).to eq(File.join(fixture('unresolvable_tier'), 'hiera.yaml'))
        expect(f.line).to eq(7) # Compliance profile tier is declared at hiera.yaml:7
      end

      it 'exposes tier and unreported_facts on meta for downstream dedupe' do
        f = findings.first
        expect(f.meta[:tier]).to eq('Compliance profile')
        expect(f.meta[:unreported_facts]).to eq(['compliance_profile'])
      end
    end

    context 'against the orphans fixture with web1 (all tier facts reported)' do
      let(:findings) { described_class.new(corpus_for('orphans', nodes: [web1])).call }

      it 'emits nothing when every tier\'s interpolation vars are covered by at least one node' do
        expect(findings).to be_empty
      end
    end

    context 'static tiers (no interpolation vars)' do
      it 'never flags Default-only tiers regardless of node facts' do
        findings = described_class.new(corpus_for('unresolvable_tier', nodes: [web1])).call
        expect(findings.map { |f| f.meta[:tier] }).not_to include('Default')
      end
    end
  end
end
