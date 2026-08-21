require 'spec_helper'

require 'driftless/legacy_facts'

RSpec.describe Driftless::LegacyFacts do
  describe '.match' do
    it 'resolves a bare legacy fact name' do
      expect(described_class.match('osfamily')).to eq('osfamily')
    end

    # Prefix policy belongs to the detectors, which strip a scope prefix and
    # decide which prefixes are worth inspecting at all.
    it 'takes a bare name and does not strip a scope prefix' do
      expect(described_class.match('::osfamily')).to be_nil
    end

    it 'does not strip a structured accessor prefix' do
      expect(described_class.match('facts.osfamily')).to be_nil
      expect(described_class.match('trusted.osfamily')).to be_nil
    end

    it 'returns nil for the modern structured equivalent' do
      expect(described_class.match('facts.os.family')).to be_nil
    end

    # Stripping :: must not turn an ordinary top-scope variable into a fact.
    it 'returns nil for a top-scope variable that is not a legacy fact' do
      expect(described_class.match('::my_site_var')).to be_nil
      expect(described_class.match('::trusted.certname')).to be_nil
    end

    it 'returns nil for a scoped name whose halves concatenate into a legacy fact' do
      expect(described_class.match('os::family')).to be_nil
    end

    it 'returns nil for an unknown name' do
      expect(described_class.match('not_a_fact_at_all')).to be_nil
    end
  end

  describe 'MAP' do
    subject(:map) { described_class::MAP }

    it 'is frozen' do
      expect(map).to be_frozen
    end

    # A key with a dot is a structured path, not a legacy fact — the sign
    # someone has added an entry from the wrong side of the rename.
    it 'keys are legacy names, never dotted paths' do
      expect(map.keys.grep(/\./)).to be_empty
    end

    it 'values are dotted structured paths' do
      expect(map.values.reject { |v| v.include?('.') }).to be_empty
    end

    it 'never maps a name to itself' do
      expect(map.select { |k, v| k == v }).to be_empty
    end

    # Placeholders mark facts that can only be enumerated per instance; they
    # would never match a real interpolation.
    it 'contains no per-instance placeholders' do
      expect((map.keys + map.values).grep(/[<>]/)).to be_empty
    end

    it 'resolves every key through .match' do
      unresolved = map.keys.reject { |k| described_class.match(k) == k }
      expect(unresolved).to be_empty
    end
  end
end
