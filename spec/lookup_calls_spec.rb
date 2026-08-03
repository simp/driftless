require 'spec_helper'

require 'driftless/lookup_calls'
require 'driftless/inputs/manifest_parser'

RSpec.describe Driftless::LookupCallExtractor do
  def fixture(name)
    File.expand_path("fixtures/manifests/#{name}", __dir__)
  end

  describe '.extract' do
    context 'against a manifest with several lookup call shapes' do
      let(:program) { Driftless::Inputs::ManifestParser.parse(fixture('lookups.pp'))[0] }
      let(:calls)   { described_class.extract(program: program, file: fixture('lookups.pp')) }

      it 'captures explicit lookup() calls with a literal string key' do
        expect(calls.map(&:key)).to include('simple::key', 'with::default')
      end

      it 'captures hiera() calls the same as lookup()' do
        expect(calls.map(&:key)).to include('legacy::key')
      end

      it 'skips calls with a dynamic (non-LiteralString) first arg' do
        # $dynamic = lookup($some_var) is present in the fixture, deliberately not captured
        expect(calls.length).to eq(3)
      end

      it 'sets has_default? based on argument count' do
        by_key = calls.each_with_object({}) { |c, h| h[c.key] = c }
        expect(by_key['simple::key'].has_default?).to be false
        expect(by_key['with::default'].has_default?).to be true
        expect(by_key['legacy::key'].has_default?).to be false
      end

      it 'records the source file for each call' do
        expect(calls).to all(have_attributes(file: fixture('lookups.pp')))
      end

      it 'records the source line for each call' do
        by_key = calls.each_with_object({}) { |c, h| h[c.key] = c }
        expect(by_key['simple::key'].line).to eq(2)
        expect(by_key['with::default'].line).to eq(3)
        expect(by_key['legacy::key'].line).to eq(4)
      end
    end

    context 'against a manifest with no lookup calls' do
      let(:program) { Driftless::Inputs::ManifestParser.parse(fixture('no_lookups.pp'))[0] }

      it 'returns an empty array' do
        expect(described_class.extract(program: program, file: fixture('no_lookups.pp'))).to eq([])
      end
    end
  end
end
