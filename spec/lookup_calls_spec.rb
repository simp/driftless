require 'spec_helper'

require 'driftless/lookup_calls'
require 'driftless/inputs/manifest_parser'
require 'driftless/inputs/epp_parser'

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

    context 'against YAML source (regex scan for %{lookup/alias/hiera(...)} interpolations)' do
      let(:yaml_source) do
        <<~YAML
          ---
          plain_key: 'plain value'
          templated:  "%{lookup('namespace::simple::key')}"
          via_alias:  "%{alias('config::alias::key')}"
          via_hiera:  "%{hiera('legacy::interp::key')}"
          two_on_one_line: "%{lookup('a::b')}/%{alias('c::d')}"
          not_a_lookup: "%{facts.hostname}"
        YAML
      end

      let(:calls) { described_class.extract_from_yaml_source(yaml_source, 'data.yaml') }

      it 'captures each lookup/alias/hiera interpolation as a LookupCall' do
        expect(calls.map(&:key)).to contain_exactly(
          'namespace::simple::key',
          'config::alias::key',
          'legacy::interp::key',
          'a::b',
          'c::d',
        )
      end

      it 'records the source line for each interpolation' do
        by_key = calls.each_with_object({}) { |c, h| h[c.key] = c }
        expect(by_key['namespace::simple::key'].line).to eq(3)
        expect(by_key['config::alias::key'].line).to eq(4)
        expect(by_key['legacy::interp::key'].line).to eq(5)
        expect(by_key['a::b'].line).to eq(6)
        expect(by_key['c::d'].line).to eq(6)
      end

      it 'sets has_default? = false for YAML-scanned calls (no default in interp syntax)' do
        expect(calls).to all(have_attributes(has_default: false))
      end

      it 'ignores %{facts.X} and other non-lookup interpolations' do
        expect(calls.map(&:key)).not_to include(a_string_matching(/facts/))
      end
    end

    context 'against an EPP template (calls in <%= %> expression blocks)' do
      def epp_fixture(name)
        File.expand_path("fixtures/templates/#{name}", __dir__)
      end

      let(:program) { Driftless::Inputs::EppParser.parse(epp_fixture('simple.epp'))[0] }
      let(:calls)   { described_class.extract(program: program, file: epp_fixture('simple.epp')) }

      it 'extracts calls from EPP expression blocks with the same code path as .pp' do
        expect(calls.map(&:key)).to contain_exactly('welcome::msg', 'server::name', 'legacy::conf')
      end

      it 'has_default? works consistently across .pp and .epp sources' do
        by_key = calls.each_with_object({}) { |c, h| h[c.key] = c }
        expect(by_key['welcome::msg'].has_default?).to be false
        expect(by_key['server::name'].has_default?).to be true
        expect(by_key['legacy::conf'].has_default?).to be false
      end
    end
  end
end
