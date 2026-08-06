require 'spec_helper'

require 'driftless/detectors/code_lookup_missing_hiera_keys'
require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/models/hiera_data_file_info'
require 'driftless/models/lookup_call'

RSpec.describe Driftless::Detectors::CodeLookupMissingHieraKeys do
  def hand_corpus(data_files: [], code_lookup_calls: [])
    Driftless::Corpus.new(
      repo_dir: nil, hiera_tiers: [], puppet_classes: {},
      data_files: data_files, reported: Driftless::Reported.new(data: {}),
      code_lookup_calls: code_lookup_calls, data_lookup_calls: [], log: nil,
    )
  end

  let(:default_yaml) do
    Driftless::HieraDataFileInfo.new(
      path: '/tmp/default.yaml',
      top_level_keys: {
        'profile::web::vhost'  => 2,
        'namespace::defined'   => 3,
      },
    )
  end

  describe '#call' do
    context 'with a mix of lookup calls (some resolvable, some missing)' do
      let(:calls) do
        [
          Driftless::LookupCall.new(key: 'profile::web::vhost',  file: 'web.pp', line: 10, has_default: false),
          Driftless::LookupCall.new(key: 'namespace::defined',   file: 'web.pp', line: 12, has_default: true),
          Driftless::LookupCall.new(key: 'never::defined::key',  file: 'web.pp', line: 14, has_default: false),
          Driftless::LookupCall.new(key: 'orphan::with::default', file: 'db.pp', line: 3,  has_default: true),
        ]
      end
      let(:corpus)   { hand_corpus(data_files: [default_yaml], code_lookup_calls: calls) }
      let(:findings) { described_class.new(corpus).call }

      it 'emits one finding per lookup call whose key is not defined in any data file' do
        expect(findings.length).to eq(2)
        expect(findings.map { |f| f.meta[:lookup_key] }).to contain_exactly(
          'never::defined::key', 'orphan::with::default',
        )
      end

      it 'does NOT emit for calls whose key IS defined (regardless of has_default)' do
        keys = findings.map { |f| f.meta[:lookup_key] }
        expect(keys).not_to include('profile::web::vhost', 'namespace::defined')
      end

      it 'records has_default in meta so consumers can distinguish silent-fallback vs compile-failure' do
        by_key = findings.each_with_object({}) { |f, h| h[f.meta[:lookup_key]] = f }
        expect(by_key['never::defined::key'].meta[:has_default]).to be false
        expect(by_key['orphan::with::default'].meta[:has_default]).to be true
      end

      it 'attaches the source file + line of the LOOKUP CALL (not the data file) to each finding' do
        f = findings.find { |x| x.meta[:lookup_key] == 'never::defined::key' }
        expect(f.path).to eq('web.pp')
        expect(f.line).to eq(14)
      end
    end

    context 'with the same missing key looked up from multiple call sites' do
      let(:calls) do
        [
          Driftless::LookupCall.new(key: 'missing::key', file: 'a.pp', line: 1, has_default: false),
          Driftless::LookupCall.new(key: 'missing::key', file: 'b.pp', line: 5, has_default: true),
        ]
      end
      let(:corpus)   { hand_corpus(data_files: [default_yaml], code_lookup_calls: calls) }
      let(:findings) { described_class.new(corpus).call }

      it 'emits per-call (not deduplicated), preserving each call site\'s context' do
        expect(findings.length).to eq(2)
        expect(findings.map { |f| [f.path, f.line, f.meta[:has_default]] }).to contain_exactly(
          ['a.pp', 1, false],
          ['b.pp', 5, true],
        )
      end
    end

    context 'with no data files at all' do
      it 'flags every lookup call as missing' do
        calls = [Driftless::LookupCall.new(key: 'anything', file: 'x.pp', line: 1, has_default: false)]
        expect(described_class.new(hand_corpus(code_lookup_calls: calls)).call.length).to eq(1)
      end
    end

    context 'with no lookup calls at all' do
      it 'emits nothing' do
        expect(described_class.new(hand_corpus(data_files: [default_yaml])).call).to be_empty
      end
    end

    context 'with lookups inside module manifests (module-local skip)' do
      # Empty data_files → no defined keys → every lookup would ordinarily be
      # flagged. Isolates the module-local skip logic from the defined-keys check.

      it 'skips lookups inside a module for that module\'s own namespace' do
        calls = [Driftless::LookupCall.new(
          key: 'mymodule::foo', file: '/repo/modules/mymodule/manifests/init.pp',
          line: 1, has_default: false,
        )]
        expect(described_class.new(hand_corpus(code_lookup_calls: calls)).call).to be_empty
      end

      it 'flags lookups inside a module that reference a DIFFERENT namespace' do
        calls = [Driftless::LookupCall.new(
          key: 'other_module::foo', file: '/repo/modules/mymodule/manifests/init.pp',
          line: 1, has_default: false,
        )]
        findings = described_class.new(hand_corpus(code_lookup_calls: calls)).call
        expect(findings.map { |f| f.meta[:lookup_key] }).to eq(['other_module::foo'])
      end

      it 'flags lookups from profile classes (profile is exempt from module-local skip)' do
        calls = [Driftless::LookupCall.new(
          key: 'profile::apache::port',
          file: '/repo/site-modules/profile/manifests/apache.pp',
          line: 1, has_default: false,
        )]
        findings = described_class.new(hand_corpus(code_lookup_calls: calls)).call
        expect(findings.map { |f| f.meta[:lookup_key] }).to eq(['profile::apache::port'])
      end

      it 'flags lookups from role classes (role is exempt from module-local skip)' do
        calls = [Driftless::LookupCall.new(
          key: 'role::web::settings',
          file: '/repo/site-modules/role/manifests/web.pp',
          line: 1, has_default: false,
        )]
        findings = described_class.new(hand_corpus(code_lookup_calls: calls)).call
        expect(findings.map { |f| f.meta[:lookup_key] }).to eq(['role::web::settings'])
      end

      it 'flags lookups from control-repo top-level manifests (no module context)' do
        calls = [Driftless::LookupCall.new(
          key: 'anything::foo', file: '/repo/manifests/site.pp',
          line: 1, has_default: false,
        )]
        findings = described_class.new(hand_corpus(code_lookup_calls: calls)).call
        expect(findings.map { |f| f.meta[:lookup_key] }).to eq(['anything::foo'])
      end

      it 'skips EPP template lookups for the containing module\'s own namespace' do
        calls = [Driftless::LookupCall.new(
          key: 'mymodule::param', file: '/repo/modules/mymodule/templates/foo.epp',
          line: 1, has_default: false,
        )]
        expect(described_class.new(hand_corpus(code_lookup_calls: calls)).call).to be_empty
      end
    end
  end
end
