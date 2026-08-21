require 'spec_helper'

require 'driftless/detectors/hierarchy_tiers_interpolating_bare_variables'
require 'driftless/models/hiera_tier'
require 'driftless/reported'

RSpec.describe Driftless::Detectors::HierarchyTiersInterpolatingBareVariables do
  def hand_corpus(hiera_tiers: [], repo_dir: nil)
    Driftless::Corpus.new(
      repo_dir:       repo_dir,
      hiera_tiers:    hiera_tiers,
      puppet_classes: {},
      data_files:     [],
      reported:       Driftless::Reported.new(data: {}),
      code_lookup_calls: [], data_lookup_calls: [],
    )
  end

  def tier(name:, interpolation_vars:, source_line: nil)
    Driftless::HieraTier.new(
      name: name, datadir: '/tmp/data', backend: :yaml_data,
      path_templates: [], interpolation_vars: interpolation_vars,
      multi_path: false, source_line: source_line,
    )
  end

  def flagged(*vars)
    described_class.new(hand_corpus(hiera_tiers: [tier(name: 't', interpolation_vars: vars)]))
      .call.map { |f| f.meta[:interpolation] }
  end

  describe '#call' do
    it 'flags an unqualified variable' do
      expect(flagged('my_role')).to eq(['my_role'])
    end

    # The name being a fact is irrelevant: bare-ness is the hazard.
    it 'flags a bare fact name regardless of whether it is current or legacy' do
      expect(flagged('kernel', 'osfamily')).to contain_exactly('kernel', 'osfamily')
    end

    it 'ignores a top-scope variable' do
      expect(flagged('::my_role', '::kernel')).to be_empty
    end

    it 'ignores structured accessors' do
      expect(flagged('facts.kernel', 'facts.os.family', 'trusted.certname')).to be_empty
    end

    # An embedded :: is a class namespace, so the name is qualified too.
    it 'ignores a class-scoped variable' do
      expect(flagged('settings::strict_variables', 'profile::web::x')).to be_empty
    end

    # `%{lookup(...)}` is a Hiera function call, not a variable reference.
    it 'ignores Hiera function calls' do
      expect(flagged('lookup("x")', 'alias("y")', 'literal("z")')).to be_empty
    end

    it 'reports each variable once per tier' do
      expect(flagged('my_role', 'my_role')).to eq(['my_role'])
    end

    it 'names the top-scope form as the remedy' do
      f = described_class.new(
        hand_corpus(hiera_tiers: [tier(name: 't', interpolation_vars: ['my_role'])]),
      ).call.first
      expect(f.message).to include('%{::my_role}')
    end

    it 'attaches findings to hiera.yaml with the tier source line' do
      corpus = hand_corpus(
        hiera_tiers: [tier(name: 't', interpolation_vars: ['my_role'], source_line: 7)],
        repo_dir: '/tmp/repo',
      )
      f = described_class.new(corpus).call.first
      expect(f.path).to eq('/tmp/repo/hiera.yaml')
      expect(f.line).to eq(7)
    end

    it 'measures each tier independently' do
      tiers = [
        tier(name: 'a', interpolation_vars: ['my_role']),
        tier(name: 'b', interpolation_vars: ['my_role']),
      ]
      findings = described_class.new(hand_corpus(hiera_tiers: tiers)).call
      expect(findings.map { |f| f.meta[:tier] }).to contain_exactly('a', 'b')
    end
  end

  describe 'exclusions' do
    around(:each) do |ex|
      original = Driftless.instance_variable_get(:@config)
      ex.run
    ensure
      Driftless.instance_variable_set(:@config, original)
    end

    def set_options(hash)
      Driftless.config = Driftless::Config.new(
        merged: { 'detectors' => { described_class.key => hash } },
      )
    end

    let(:tiers) do
      [
        tier(name: 'per-env',  interpolation_vars: ['environment']),
        tier(name: 'per-role', interpolation_vars: ['my_role']),
      ]
    end

    def tiers_flagged
      described_class.new(hand_corpus(hiera_tiers: tiers)).call.map { |f| f.meta[:tier] }
    end

    it 'flags both tiers with no exclusions set' do
      set_options({})
      expect(tiers_flagged).to contain_exactly('per-env', 'per-role')
    end

    it 'honors exclude_tiers' do
      set_options('exclude_tiers' => ['per-env'])
      expect(tiers_flagged).to eq(['per-role'])
    end

    # The escape hatch for a bare built-in a site does not intend to qualify.
    it 'honors exclude_facts' do
      set_options('exclude_facts' => ['environment'])
      expect(tiers_flagged).to eq(['per-role'])
    end
  end
end
