require 'spec_helper'
require 'driftless/inputs/epp_parser'

RSpec.describe Driftless::Inputs::EppParser do
  def fixture(name)
    File.expand_path("../fixtures/templates/#{name}", __dir__)
  end

  describe '.parse' do
    context 'with a well-formed EPP template' do
      let(:result)   { described_class.parse(fixture('simple.epp')) }
      let(:program)  { result[0] }
      let(:findings) { result[1] }

      it 'returns a materialized Puppet::Pops::Model::Program (not the Factory)' do
        expect(program).to be_a(Puppet::Pops::Model::Program)
      end

      it 'emits no findings' do
        expect(findings).to be_empty
      end
    end

    context 'with a malformed EPP template' do
      let(:result) { described_class.parse(fixture('malformed.epp')) }

      it 'returns nil for the program' do
        expect(result[0]).to be_nil
      end

      it 'emits one code:parse-error finding scoped to the file' do
        expect(result[1].length).to eq(1)
        expect(result[1].first.key).to eq('code:parse-error')
        expect(result[1].first.path).to eq(fixture('malformed.epp'))
      end
    end

    context 'with a nonexistent path' do
      let(:result) { described_class.parse('/does/not/exist.epp') }

      it 'emits a code:parse-error finding rather than crashing' do
        expect(result[0]).to be_nil
        expect(result[1].map(&:key)).to eq(['code:parse-error'])
      end
    end
  end
end
