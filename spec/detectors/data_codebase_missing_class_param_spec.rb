require 'spec_helper'

require 'driftless/detectors/data_codebase_missing_class_param'
require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/models/hiera_data_file_info'
require 'driftless/models/puppet_class'
require 'driftless/models/class_parameter'
require 'driftless/models/lookup_call'

RSpec.describe Driftless::Detectors::DataCodebaseMissingClassParam do
  def hand_corpus(data_files: [], puppet_classes: {}, lookup_calls: [])
    Driftless::Corpus.new(
      repo_dir: nil, hiera_tiers: [], puppet_classes: puppet_classes,
      data_files: data_files, reported: Driftless::Reported.new(data: {}),
      lookup_calls: lookup_calls, log: nil,
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

    context 'exemption via explicit lookup() call' do
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
        hand_corpus(data_files: [df], puppet_classes: { 'profile::web' => web_class }, lookup_calls: [lookup])
      end

      it 'exempts the key from missing-param findings' do
        expect(described_class.new(corpus).call).to be_empty
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
end
