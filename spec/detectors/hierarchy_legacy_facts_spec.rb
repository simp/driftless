require 'spec_helper'

require 'driftless/detectors/hierarchy_legacy_facts'
require 'driftless/models/hiera_tier'
require 'driftless/reported'

RSpec.describe Driftless::Detectors::HierarchyLegacyFacts do
  def hand_corpus(hiera_tiers: [])
    Driftless::Corpus.new(
      repo_dir:       nil,
      hiera_tiers:    hiera_tiers,
      puppet_classes: {},
      data_files:     [],
      reported:       Driftless::Reported.new(data: {}),
      lookup_calls:   [],
      log:            nil,
    )
  end

  def tier(name:, interpolation_vars:)
    Driftless::HieraTier.new(
      name:               name,
      datadir:            '/tmp/data',
      backend:            :yaml_data,
      path_templates:     [],
      interpolation_vars: interpolation_vars,
      multi_path:         false,
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

  it 'flags facts.-prefixed legacy fact names' do
    tiers    = [tier(name: 'per-node', interpolation_vars: ['facts.hostname'])]
    findings = described_class.new(hand_corpus(hiera_tiers: tiers)).call
    expect(findings.size).to eq(1)
    expect(findings.first.meta).to include(
      legacy: 'hostname', modern: 'networking.hostname', interpolation: 'facts.hostname'
    )
  end

  it 'emits one finding per unique legacy fact per tier' do
    tiers    = [tier(name: 'per-node', interpolation_vars: %w[hostname fqdn osfamily])]
    findings = described_class.new(hand_corpus(hiera_tiers: tiers)).call
    expect(findings.map { |f| f.meta[:legacy] }).to contain_exactly('hostname', 'fqdn', 'osfamily')
  end

  it 'dedupes when the same legacy fact appears via both bare and facts.- form in one tier' do
    tiers    = [tier(name: 't', interpolation_vars: %w[osfamily facts.osfamily])]
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
end
