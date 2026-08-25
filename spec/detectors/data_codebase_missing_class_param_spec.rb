require 'spec_helper'

require 'driftless/detectors/data_codebase_missing_class_param'
require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/models/hiera_data_file_info'
require 'driftless/models/puppet_class'
require 'driftless/models/class_parameter'
require 'driftless/models/lookup_call'

RSpec.describe Driftless::Detectors::DataCodebaseMissingClassParam do
  def hand_corpus(data_files: [], puppet_classes: {}, code_lookup_calls: [])
    Driftless::Corpus.new(
      repo_dir: nil, hiera_tiers: [], puppet_classes: puppet_classes,
      data_files: data_files, reported: Driftless::Reported.new(data: {}),
      code_lookup_calls: code_lookup_calls, data_lookup_calls: [],
    )
  end

  let(:web_class) do
    Driftless::PuppetClass.new(
      fqname: 'profile::web', file: 'web.pp',
      params: [
        Driftless::ClassParameter.new(name: 'vhost', default_expr: nil, type_expr: nil),
        Driftless::ClassParameter.new(name: 'ssl',   default_expr: nil, type_expr: nil),
      ],
      role: false, profile: true,
    )
  end

  describe '#call' do
    context 'with a mix of valid and invalid parameter references on an existing class' do
      let(:df) do
        Driftless::HieraDataFileInfo.new(
          path: '/tmp/default.yaml',
          top_level_keys: {
            'profile::web::vhost'     => 2,   # ✓ valid param
            'profile::web::ssl'       => 3,   # ✓ valid param
            'profile::web::bad_param' => 4,   # ✗ class exists, param doesnt
            'profile::web::other_bad' => 5,   # ✗ same
          },
        )
      end
      let(:corpus) { hand_corpus(data_files: [df], puppet_classes: { 'profile::web' => web_class }) }
      let(:findings) { described_class.new(corpus).call }

      it 'emits one finding per invalid param on an existing class' do
        expect(findings.length).to eq(2)
      end

      it 'records line + class + param + valid-params list in each finding' do
        f = findings.find { |x| x.line == 4 }
        expect(f.meta[:class_name]).to eq('profile::web')
        expect(f.meta[:param_name]).to eq('bad_param')
        expect(f.meta[:valid_params]).to eq(%w[vhost ssl])
      end

      it 'does NOT double-fire when the class itself is missing (that is the other detector)' do
        df_missing = Driftless::HieraDataFileInfo.new(
          path: '/tmp/default.yaml',
          top_level_keys: { 'nonexistent::class::param' => 2 },
        )
        c = hand_corpus(data_files: [df_missing])
        expect(described_class.new(c).call).to be_empty
      end
    end

    context 'a namespace-only key under a class that exists' do
      around do |ex|
        original = Driftless.instance_variable_get(:@config)
        ex.run
      ensure
        Driftless.instance_variable_set(:@config, original)
      end

      def set_config(hash)
        Driftless.config = Driftless::Config.new(merged: hash)
      end

      def allow_role_profile_keys
        set_config('detectors' => {
          'data:codebase-missing-class-param' => { 'allow_role_profile_keys' => true },
        })
      end

      let(:df) do
        Driftless::HieraDataFileInfo.new(
          path: '/tmp/default.yaml',
          top_level_keys: { 'profile::web::not_a_param_but_ns' => 5 },
        )
      end
      let(:lookup) do
        Driftless::LookupCall.new(
          key: 'profile::web::not_a_param_but_ns',
          file: 'web.pp', line: 10, has_default: false,
        )
      end
      let(:corpus) do
        hand_corpus(data_files: [df], puppet_classes: { 'profile::web' => web_class }, code_lookup_calls: [lookup])
      end

      it 'reports it by default, even though an explicit lookup() fetches it' do
        set_config({})
        findings = described_class.new(corpus).call
        expect(findings.length).to eq(1)
        expect(findings.first.meta[:param_name]).to eq('not_a_param_but_ns')
      end

      it 'allows it under allow_role_profile_keys' do
        allow_role_profile_keys
        expect(described_class.new(corpus).call).to be_empty
      end

      it 'still reports a misspelled param under a profile, which no lookup() fetches' do
        allow_role_profile_keys
        typo = Driftless::HieraDataFileInfo.new(
          path: '/tmp/default.yaml',
          top_level_keys: { 'profile::web::vhsot' => 6 },
        )
        c = hand_corpus(data_files: [typo], puppet_classes: { 'profile::web' => web_class },
                        code_lookup_calls: [lookup])
        expect(described_class.new(c).call.map { |f| f.meta[:param_name] }).to eq(['vhsot'])
      end

      it 'does not allow it for a class that is neither a role nor a profile' do
        allow_role_profile_keys
        module_class = Driftless::PuppetClass.new(
          fqname: 'apache', file: 'apache.pp',
          params: [Driftless::ClassParameter.new(name: 'port', default_expr: nil, type_expr: nil)],
          role: false, profile: false,
        )
        upstream = Driftless::HieraDataFileInfo.new(
          path: '/tmp/default.yaml',
          top_level_keys: { 'apache::not_a_param_but_ns' => 7 },
        )
        c = hand_corpus(
          data_files: [upstream], puppet_classes: { 'apache' => module_class },
          code_lookup_calls: [Driftless::LookupCall.new(key: 'apache::not_a_param_but_ns',
                                                        file: 'x.pp', line: 1, has_default: false)],
        )
        expect(described_class.new(c).call.map { |f| f.meta[:param_name] }).to eq(['not_a_param_but_ns'])
      end
    end

    context 'with data keys that do not use :: (single segment)' do
      let(:df) do
        Driftless::HieraDataFileInfo.new(
          path: '/tmp/default.yaml',
          top_level_keys: { 'plain' => 2 },
        )
      end
      let(:corpus) { hand_corpus(data_files: [df]) }

      it 'ignores them' do
        expect(described_class.new(corpus).call).to be_empty
      end
    end
  end
  describe 'exclude_classes' do
    around do |ex|
      original = Driftless.instance_variable_get(:@config)
      ex.run
    ensure
      Driftless.instance_variable_set(:@config, original)
    end

    def set_exclusions(*patterns)
      Driftless.config = Driftless::Config.new(merged: {
        'detectors' => { 'data:codebase-missing-class-param' => { 'exclude_classes' => patterns } },
      })
    end

    let(:web_class) do
      Driftless::PuppetClass.new(
        fqname: 'profile::web', file: 'web.pp',
        params: [Driftless::ClassParameter.new(name: 'port', default_expr: nil, type_expr: nil)],
        role: false, profile: true,
      )
    end

    let(:db_class) do
      Driftless::PuppetClass.new(
        fqname: 'other::db', file: 'db.pp',
        params: [Driftless::ClassParameter.new(name: 'host', default_expr: nil, type_expr: nil)],
        role: false, profile: false,
      )
    end

    let(:df) do
      Driftless::HieraDataFileInfo.new(
        path: '/tmp/default.yaml',
        top_level_keys: { 'profile::web::bogus' => 2, 'other::db::bogus' => 3 },
      )
    end

    let(:classes) do
      described_class.new(
        hand_corpus(
          data_files: [df],
          puppet_classes: { 'profile::web' => web_class, 'other::db' => db_class },
        ),
      ).call.map { |f| f.meta[:class_name] }
    end

    it 'flags a bad param on every class when nothing is excluded' do
      Driftless.config = Driftless::Config.new(merged: {})
      expect(classes).to contain_exactly('profile::web', 'other::db')
    end

    it 'drops the class named by the pattern' do
      set_exclusions('profile::*')
      expect(classes).to eq(['other::db'])
    end
  end
end
