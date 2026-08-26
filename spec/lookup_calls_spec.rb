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

      it 'records which function made each call' do
        by_key = calls.each_with_object({}) { |c, h| h[c.key] = c }
        expect(by_key['simple::key'].function).to eq('lookup')
        expect(by_key['legacy::key'].function).to eq('hiera')
      end

      it 'skips calls with a dynamic (non-LiteralString) first arg' do
        # $dynamic = lookup($some_var) is present in the fixture, deliberately not captured
        expect(calls.length).to eq(3)
      end

      it 'sets has_default? based on Puppet lookup() signature semantics' do
        by_key = calls.each_with_object({}) { |c, h| h[c.key] = c }
        expect(by_key['simple::key'].has_default?).to be false      # 1 arg
        expect(by_key['with::default'].has_default?).to be true     # 4-arg positional
        expect(by_key['legacy::key'].has_default?).to be false      # 1 arg (hiera)
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

    context 'has_default? for each Puppet lookup() call form' do
      # Parses tiny manifest strings directly (bypassing ManifestParser, which
      # only accepts file paths) and checks has_default? on the resulting
      # LookupCall. One test per Puppet lookup() argument form.
      def parse_and_extract(code)
        require 'puppet/pops'
        program = Puppet::Pops::Parser::EvaluatingParser.new.parse_string(code)
        described_class.extract(program: program, file: '(inline)')
      end

      it 'no default when only key (1 arg)' do
        expect(parse_and_extract("$x = lookup('k')").first.has_default?).to be false
      end

      it 'no default when key + type (2 args)' do
        expect(parse_and_extract("$x = lookup('k', String)").first.has_default?).to be false
      end

      it 'no default when key + type + merge (3 args)' do
        expect(parse_and_extract("$x = lookup('k', String, 'first')").first.has_default?).to be false
      end

      it 'has default when 4-arg positional (name, type, merge, default)' do
        expect(parse_and_extract("$x = lookup('k', String, 'first', 'fallback')").first.has_default?).to be true
      end

      it 'has default when block form (lambda present)' do
        expect(parse_and_extract("$x = lookup('k') |$key| { 'from_block' }").first.has_default?).to be true
      end

      # Hash form (lookup({'name' => 'k', 'default_value' => 'v'})) is not
      # extracted — literal_first_arg() requires a LiteralString first arg.
    end

    context 'against a manifest with no lookup calls' do
      let(:program) { Driftless::Inputs::ManifestParser.parse(fixture('no_lookups.pp'))[0] }

      it 'returns an empty array' do
        expect(described_class.extract(program: program, file: fixture('no_lookups.pp'))).to eq([])
      end
    end

    context 'against YAML values (regex scan for %{lookup/alias/hiera(...)} interpolations)' do
      let(:yaml_source) do
        <<~YAML
          ---
          plain_key: 'plain value'
          templated:  "%{lookup('namespace::simple::key')}"
          via_alias:  "%{alias('config::alias::key')}"
          via_hiera:  "%{hiera('legacy::interp::key')}"
          two_on_one_line: "%{lookup('a::b')}/%{alias('c::d')}"
          not_a_lookup: "%{facts.hostname}"
          # in_comment: "%{lookup('comment::key')}"
        YAML
      end

      let(:value_lines) do
        Driftless::HieraDataFileInfo.new(path: 'data.yaml', top_level_keys: {}, source: yaml_source).value_lines
      end
      let(:calls) { described_class.extract_from_yaml_values(value_lines, 'data.yaml') }

      it 'ignores a lookup interpolation inside a comment' do
        expect(calls.map(&:key)).not_to include('comment::key')
      end

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

      it 'records which function each interpolation used' do
        by_key = calls.each_with_object({}) { |c, h| h[c.key] = c }
        expect(by_key['namespace::simple::key'].function).to eq('lookup')
        expect(by_key['config::alias::key'].function).to eq('alias')
        expect(by_key['legacy::interp::key'].function).to eq('hiera')
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
