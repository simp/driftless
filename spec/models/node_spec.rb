require 'spec_helper'
require 'driftless/models/node'

RSpec.describe Driftless::Node do
  subject(:node) do
    described_class.new(
      certname: 'web1.example.com',
      facts: {
        'hostname' => 'web1',
        'os' => { 'family' => 'RedHat', 'release' => { 'major' => '9' } },
      },
      trusted: {
        'certname' => 'web1.example.com',
        'hostname' => 'web1',
      },
    )
  end

  describe 'environment field' do
    it 'defaults to nil when not supplied' do
      expect(node.environment).to be_nil
    end

    it 'stores an environment when supplied' do
      n = described_class.new(certname: 'x', environment: 'production', facts: {}, trusted: {})
      expect(n.environment).to eq('production')
    end
  end

  describe '.memoized_split_fact_paths' do
    before(:each) { described_class.memoized_split_fact_paths.clear }

    it 'records which hash a key is rooted in, and the segments to dig with' do
      node.fact('facts.os.family')
      expect(described_class.memoized_split_fact_paths['facts.os.family']).to eq([:facts, %w[os family]])
    end

    # :unprefixed rather than :facts — the key declared no namespace, and it
    # may name a variable rather than a fact.
    it 'records an unprefixed key as declaring no namespace' do
      node.fact('hostname')
      expect(described_class.memoized_split_fact_paths['hostname']).to eq([:unprefixed, %w[hostname]])
    end

    it 'distinguishes an explicit facts. reference from a bare name' do
      node.fact('facts.hostname')
      node.fact('hostname')
      expect(described_class.memoized_split_fact_paths['facts.hostname']).to eq([:facts, %w[hostname]])
      expect(described_class.memoized_split_fact_paths['hostname']).to eq([:unprefixed, %w[hostname]])
    end

    it 'parses a repeated key only once' do
      n = described_class.new(certname: 'x', facts: { 'os' => { 'family' => 'RedHat' } })
      expect(n).to receive(:parse_key).once.and_call_original
      3.times { n.fact('facts.os.family') }
    end

    it 'shares a parse across nodes' do
      facts = { 'os' => { 'family' => 'RedHat' } }
      described_class.new(certname: 'web1.example.com', facts: facts).fact('facts.os.family')
      other = described_class.new(certname: 'web2.example.com', facts: facts)
      expect(other).not_to receive(:parse_key)
      expect(other.fact('facts.os.family')).to eq('RedHat')
    end
  end

  describe '#fact' do
    it 'resolves an explicit facts.X path against the facts hash' do
      expect(node.fact('facts.os.family')).to eq('RedHat')
    end

    it 'traverses dotted paths into nested hashes' do
      expect(node.fact('facts.os.release.major')).to eq('9')
    end

    it 'resolves trusted.X from trusted even when facts carries the same name' do
      n = described_class.new(
        certname: 'web1.example.com',
        facts:    { 'certname' => 'spoofed.example.com' },
        trusted:  { 'certname' => 'web1.example.com' },
      )
      expect(n.fact('trusted.certname')).to eq('web1.example.com')
    end

    it 'resolves an explicit trusted.X path against the trusted hash' do
      expect(node.fact('trusted.certname')).to eq('web1.example.com')
    end

    it 'resolves a bare name from facts (legacy alias)' do
      expect(node.fact('hostname')).to eq('web1')
    end

    it 'does not resolve a bare name from trusted' do
      expect(node.fact('certname')).to be_nil
      expect(node.fact('trusted.certname')).to eq('web1.example.com')
    end

    it 'returns a false fact value rather than reporting it absent' do
      n = described_class.new(certname: 'x', facts: { 'is_virtual' => false })
      expect(n.fact('is_virtual')).to be(false)
      expect(n.fact('facts.is_virtual')).to be(false)
    end

    it 'returns nil when a facts.X path does not resolve' do
      expect(node.fact('facts.no_such_fact')).to be_nil
      expect(node.fact('facts.os.no_such_subfact')).to be_nil
    end

    it 'returns nil when a bare name is in neither facts nor trusted' do
      expect(node.fact('nowhere')).to be_nil
    end

    it 'traverses quoted segments (SubLookup#split_key contract)' do
      node_with_spaces = described_class.new(
        certname: 'x',
        facts:    { 'os' => { 'quirky key' => 'weird-value' } },
        trusted:  {},
      )
      expect(node_with_spaces.fact('facts.os."quirky key"')).to eq('weird-value')
    end
  end
end
