require 'spec_helper'
require 'driftless/inputs/manifest_parser'

RSpec.describe Driftless::Inputs::ManifestParser do
  def fixture(name)
    File.expand_path("../fixtures/manifests/#{name}", __dir__)
  end

  describe '.parse' do
    context 'with a well-formed manifest' do
      let(:result)   { described_class.parse(fixture('lookups.pp')) }
      let(:program)  { result[0] }
      let(:findings) { result[1] }

      it 'returns a Puppet::Pops::Model::Program' do
        expect(program).to be_a(Puppet::Pops::Model::Program)
      end

      it 'emits no findings' do
        expect(findings).to be_empty
      end
    end

    context 'with a manifest that has no lookup calls' do
      let(:result) { described_class.parse(fixture('no_lookups.pp')) }

      it 'still parses successfully' do
        expect(result[0]).to be_a(Puppet::Pops::Model::Program)
        expect(result[1]).to be_empty
      end
    end

    context 'with a malformed manifest' do
      let(:result)   { described_class.parse(fixture('malformed.pp')) }
      let(:program)  { result[0] }
      let(:findings) { result[1] }

      it 'returns nil for the program' do
        expect(program).to be_nil
      end

      it 'emits one code:parse-error finding scoped to the file' do
        expect(findings.length).to eq(1)
        expect(findings.first.key).to eq('code:parse-error')
        expect(findings.first.path).to eq(fixture('malformed.pp'))
      end
    end

    context 'with a nonexistent path' do
      let(:result) { described_class.parse('/does/not/exist.pp') }

      it 'emits a code:parse-error finding rather than crashing' do
        expect(result[0]).to be_nil
        expect(result[1].map(&:key)).to eq(['code:parse-error'])
      end
    end
  end
end
