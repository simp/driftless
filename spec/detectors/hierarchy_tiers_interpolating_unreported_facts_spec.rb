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
    tiers, = Driftless::Inputs::HierarchyLoader.load(fixture(fixture_name))
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

    context 'top-scope variables (not facts, so never in a factset)' do
      around(:each) do |ex|
        original = Driftless.instance_variable_get(:@config)
        ex.run
      ensure
        Driftless.instance_variable_set(:@config, original)
      end

      def set_puppet_config(opts)
        Driftless.config = Driftless::Config.new(merged: { 'puppet' => opts })
      end

      let(:tiers_flagged) do
        described_class.new(corpus_for('top_scope_tiers', nodes: [web1])).call.map { |f| f.meta[:tier] }
      end

      it 'skips the built-in server variables and reports the rest' do
        set_puppet_config({})
        expect(tiers_flagged).to eq(['Region'])
      end

      it 'skips a name listed in puppet.top_scope_variables' do
        set_puppet_config('top_scope_variables' => ['site_region'])
        expect(tiers_flagged).to be_empty
      end

      it 'reports the server variables when puppet.allow_builtin_top_scope_variables is false' do
        set_puppet_config('allow_builtin_top_scope_variables' => false)
        expect(tiers_flagged).to contain_exactly('Environment', 'Server environment', 'Strict', 'Region')
      end
    end

    context 'with exclude_tiers / exclude_facts configured' do
      around(:each) do |ex|
        original = Driftless.instance_variable_get(:@config)
        ex.run
      ensure
        Driftless.instance_variable_set(:@config, original)
      end

      def set_detector_config(opts)
        Driftless.config = Driftless::Config.new(merged: {
          'detectors' => { described_class.key => opts },
        })
      end

      it 'exclude_tiers by literal name suppresses that tier\'s finding' do
        set_detector_config('exclude_tiers' => ['Compliance profile'])
        findings = described_class.new(corpus_for('unresolvable_tier', nodes: [web1])).call
        expect(findings).to be_empty
      end

      it 'exclude_tiers accepts glob patterns' do
        set_detector_config('exclude_tiers' => ['Comp*'])
        findings = described_class.new(corpus_for('unresolvable_tier', nodes: [web1])).call
        expect(findings).to be_empty
      end

      it 'exclude_facts by literal name removes the fact from the "unreported" check' do
        set_detector_config('exclude_facts' => ['compliance_profile'])
        findings = described_class.new(corpus_for('unresolvable_tier', nodes: [web1])).call
        # The tier's only interpolation var is now excluded → nothing left unreported → no finding
        expect(findings).to be_empty
      end

      it 'exclude_facts accepts glob patterns' do
        set_detector_config('exclude_facts' => ['comp*'])
        findings = described_class.new(corpus_for('unresolvable_tier', nodes: [web1])).call
        expect(findings).to be_empty
      end

      it 'a non-matching exclude leaves the finding intact' do
        set_detector_config(
          'exclude_tiers' => ['SomeOtherTier'],
          'exclude_facts' => ['some_other_fact'],
        )
        findings = described_class.new(corpus_for('unresolvable_tier', nodes: [web1])).call
        expect(findings.length).to eq(1)
        expect(findings.first.meta[:tier]).to eq('Compliance profile')
      end
    end
  end
end
