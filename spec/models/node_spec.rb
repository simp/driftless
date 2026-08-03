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

  describe '#fact' do
    it 'resolves an explicit facts.X path against the facts hash' do
      expect(node.fact('facts.os.family')).to eq('RedHat')
    end

    it 'traverses dotted paths into nested hashes' do
      expect(node.fact('facts.os.release.major')).to eq('9')
    end

    it 'resolves an explicit trusted.X path against the trusted hash' do
      expect(node.fact('trusted.certname')).to eq('web1.example.com')
    end

    it 'resolves a bare name from facts (legacy alias)' do
      expect(node.fact('hostname')).to eq('web1')
    end

    it 'falls back to trusted for a bare name that is only in trusted' do
      expect(node.fact('certname')).to eq('web1.example.com')
    end

    it 'returns nil when a facts.X path does not resolve' do
      expect(node.fact('facts.no_such_fact')).to be_nil
      expect(node.fact('facts.os.no_such_subfact')).to be_nil
    end

    it 'returns nil when a bare name is in neither facts nor trusted' do
      expect(node.fact('nowhere')).to be_nil
    end
  end
end
