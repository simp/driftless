require 'spec_helper'

require 'driftless/hierarchy_interpolator'
require 'driftless/models/node'

RSpec.describe Driftless::HierarchyInterpolator do
  let(:node) do
    Driftless::Node.new(
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

  let(:interpolator) { described_class.new(node) }
  let(:unresolved)   { described_class::UnresolvedInterpolation }

  describe '#render' do
    it 'returns a template with no vars unchanged' do
      expect(interpolator.render('default.yaml')).to eq('default.yaml')
    end

    it 'renders %{facts.X} against the facts hash' do
      expect(interpolator.render('%{facts.hostname}')).to eq('web1')
    end

    it 'renders %{trusted.X} against the trusted hash' do
      expect(interpolator.render('hosts/%{trusted.certname}.yaml')).to eq('hosts/web1.example.com.yaml')
    end

    it 'traverses dotted paths through nested hashes' do
      expect(interpolator.render('os/%{facts.os.family}/%{facts.os.release.major}.yaml'))
        .to eq('os/RedHat/9.yaml')
    end

    it 'resolves a bare fact name via the legacy facts-first alias' do
      expect(interpolator.render('%{hostname}')).to eq('web1')
    end

    it 'returns UnresolvedInterpolation when any var cannot be resolved' do
      expect(interpolator.render('%{facts.does_not_exist}')).to equal(unresolved)
    end

    it 'returns UnresolvedInterpolation if any of several vars is unresolvable' do
      expect(interpolator.render('%{facts.os.family}/%{facts.no_such}.yaml')).to equal(unresolved)
    end

    it 'does not leak unresolved state across successive render calls' do
      expect(interpolator.render('%{facts.os.family}.yaml')).to eq('RedHat.yaml')
      expect(interpolator.render('%{facts.no_such}')).to equal(unresolved)
      expect(interpolator.render('%{facts.os.family}.yaml')).to eq('RedHat.yaml')
    end

    it 'exposes an unresolved? predicate' do
      expect(described_class.unresolved?(unresolved)).to be true
      expect(described_class.unresolved?('default.yaml')).to be false
    end
  end
end
