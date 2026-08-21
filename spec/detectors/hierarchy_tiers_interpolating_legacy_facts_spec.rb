require 'spec_helper'

require 'driftless/detectors/hierarchy_tiers_interpolating_legacy_facts'
require 'driftless/models/hiera_tier'
require 'driftless/reported'

RSpec.describe Driftless::Detectors::HierarchyTiersInterpolatingLegacyFacts do
  def hand_corpus(hiera_tiers: [], repo_dir: nil)
    Driftless::Corpus.new(
      repo_dir:       repo_dir,
      hiera_tiers:    hiera_tiers,
      puppet_classes: {},
      data_files:     [],
      reported:       Driftless::Reported.new(data: {}),
      code_lookup_calls:   [], data_lookup_calls: [],
    )
  end

  def tier(name:, interpolation_vars:, source_line: nil)
    Driftless::HieraTier.new(
      name:               name,
      datadir:            '/tmp/data',
      backend:            :yaml_data,
      path_templates:     [],
      interpolation_vars: interpolation_vars,
      multi_path:         false,
      source_line:        source_line,
    )
  end

  it 'emits no findings when interpolation_vars are all modern' do
    tiers    = [tier(name: 'per-os', interpolation_vars: %w[facts.os.family facts.networking.fqdn])]
    findings = described_class.new(hand_corpus(hiera_tiers: tiers)).call
    expect(findings).to be_empty
  end

  it 'flags bare legacy fact names' do
    tiers    = [tier(name: 'per-os', interpolation_vars: ['osfamily'])]
    findings = described_class.new(hand_corpus(hiera_tiers: tiers)).call
    expect(findings.size).to eq(1)
    expect(findings.first.meta).to include(
      tier: 'per-os', legacy: 'osfamily', modern: 'os.family', interpolation: 'osfamily'
    )
  end

  # facts. and trusted. are structured accessors, so what follows is a
  # structured fact by construction, never a legacy one.
  it 'ignores structured accessor forms' do
    tiers = [tier(name: 'per-node', interpolation_vars: %w[facts.hostname trusted.hostname])]
    expect(described_class.new(hand_corpus(hiera_tiers: tiers)).call).to be_empty
  end

  it 'flags the top-scope form' do
    tiers    = [tier(name: 'per-node', interpolation_vars: ['::hostname'])]
    findings = described_class.new(hand_corpus(hiera_tiers: tiers)).call
    expect(findings.size).to eq(1)
    expect(findings.first.meta).to include(
      legacy: 'hostname', modern: 'networking.hostname', interpolation: '::hostname'
    )
  end

  it 'emits one finding per unique legacy fact per tier' do
    tiers    = [tier(name: 'per-node', interpolation_vars: %w[hostname fqdn osfamily])]
    findings = described_class.new(hand_corpus(hiera_tiers: tiers)).call
    expect(findings.map { |f| f.meta[:legacy] }).to contain_exactly('hostname', 'fqdn', 'osfamily')
  end

  it 'dedupes when the same legacy fact appears via both bare and top-scope form in one tier' do
    tiers    = [tier(name: 't', interpolation_vars: %w[osfamily ::osfamily])]
    findings = described_class.new(hand_corpus(hiera_tiers: tiers)).call
    expect(findings.size).to eq(1)
  end

  it 'reports findings independently across multiple tiers' do
    tiers    = [
      tier(name: 't1', interpolation_vars: ['osfamily']),
      tier(name: 't2', interpolation_vars: ['osfamily']),
    ]
    findings = described_class.new(hand_corpus(hiera_tiers: tiers)).call
    expect(findings.size).to eq(2)
    expect(findings.map { |f| f.meta[:tier] }).to contain_exactly('t1', 't2')
  end

  describe 'path and line attribution' do
    it 'attaches findings to hiera.yaml with the tier\'s source_line when both are available' do
      tiers    = [tier(name: 'per-os', interpolation_vars: ['osfamily'], source_line: 12)]
      corpus   = hand_corpus(hiera_tiers: tiers, repo_dir: '/tmp/repo')
      findings = described_class.new(corpus).call
      expect(findings.first.path).to eq('/tmp/repo/hiera.yaml')
      expect(findings.first.line).to eq(12)
    end

    it 'leaves path nil when the corpus has no repo_dir' do
      tiers    = [tier(name: 'per-os', interpolation_vars: ['osfamily'], source_line: 12)]
      findings = described_class.new(hand_corpus(hiera_tiers: tiers)).call
      expect(findings.first.path).to be_nil
      expect(findings.first.line).to eq(12)
    end

    it 'leaves line nil when the tier has no source_line' do
      tiers    = [tier(name: 'per-os', interpolation_vars: ['osfamily'])]
      findings = described_class.new(hand_corpus(hiera_tiers: tiers, repo_dir: '/tmp/repo')).call
      expect(findings.first.line).to be_nil
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
        tier(name: 'per-os',     interpolation_vars: ['osfamily']),
        tier(name: 'per-domain', interpolation_vars: ['::domain']),
      ]
    end

    def flagged
      described_class.new(hand_corpus(hiera_tiers: tiers)).call.map { |f| f.meta[:tier] }
    end

    it 'flags both tiers when no exclusions are set' do
      set_options({})
      expect(flagged).to contain_exactly('per-os', 'per-domain')
    end

    it 'drops a tier named by exclude_tiers' do
      set_options('exclude_tiers' => ['per-os'])
      expect(flagged).to eq(['per-domain'])
    end

    it 'matches exclude_tiers as a glob, not a literal' do
      set_options('exclude_tiers' => ['per-*'])
      expect(flagged).to be_empty
    end

    it 'drops a fact named by exclude_facts' do
      set_options('exclude_facts' => ['osfamily'])
      expect(flagged).to eq(['per-domain'])
    end

    it 'matches exclude_facts against the resolved fact, not just the interpolation' do
      # The tier interpolates `::domain`, which names legacy fact `domain`.
      set_options('exclude_facts' => ['domain'])
      expect(flagged).to eq(['per-os'])
    end

    it 'matches exclude_facts against the interpolation as written' do
      set_options('exclude_facts' => ['::domain'])
      expect(flagged).to eq(['per-os'])
    end
  end
  it 'flags top-scope legacy fact names' do
    tiers    = [tier(name: 'per-os', interpolation_vars: ['::osfamily'])]
    findings = described_class.new(hand_corpus(hiera_tiers: tiers)).call
    expect(findings.size).to eq(1)
    expect(findings.first.meta).to include(
      legacy: 'osfamily', modern: 'os.family', interpolation: '::osfamily',
    )
  end

  it 'ignores a top-scope variable that is not a legacy fact' do
    tiers = [tier(name: 'per-site', interpolation_vars: ['::my_site_var'])]
    expect(described_class.new(hand_corpus(hiera_tiers: tiers)).call).to be_empty
  end

  it 'dedupes a legacy fact reached via bare and top-scope form in one tier' do
    tiers = [tier(name: 't', interpolation_vars: %w[osfamily ::osfamily])]
    expect(described_class.new(hand_corpus(hiera_tiers: tiers)).call.size).to eq(1)
  end

end
