require 'spec_helper'

require 'driftless/detectors/data_codebase_missing_class'
require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/models/hiera_data_file_info'
require 'driftless/models/puppet_class'
require 'driftless/models/class_parameter'
require 'driftless/models/lookup_call'

RSpec.describe Driftless::Detectors::DataCodebaseMissingClass do
  def hand_corpus(data_files: [], puppet_classes: {}, code_lookup_calls: [])
    Driftless::Corpus.new(
      repo_dir: nil, hiera_tiers: [], puppet_classes: puppet_classes,
      data_files: data_files, reported: Driftless::Reported.new(data: {}),
      code_lookup_calls: code_lookup_calls, data_lookup_calls: [],
    )
  end

  let(:profile_base_class) do
    Driftless::PuppetClass.new(
      fqname: 'profile::base', file: 'x.pp',
      params: [Driftless::ClassParameter.new(name: 'ensure', default_expr: nil, type_expr: nil)],
      role: false, profile: true,
    )
  end

  describe '#call' do
    context 'with a mix of keys that reference existing and non-existing classes' do
      let(:df) do
        Driftless::HieraDataFileInfo.new(
          path: '/tmp/default.yaml',
          top_level_keys: {
            'profile::base::ensure'      => 2,
            'profile::nonexistent::foo'  => 3,
            'another::missing::param'    => 4,
          },
        )
      end
      let(:corpus) do
        hand_corpus(data_files: [df], puppet_classes: { 'profile::base' => profile_base_class })
      end
      let(:findings) { described_class.new(corpus).call }

      it 'emits one finding per key whose class is not defined' do
        expect(findings.length).to eq(2)
      end

      it 'records path + line + missing class name for each finding' do
        pairs = findings.map { |f| [f.line, f.meta[:class_name]] }
        expect(pairs).to contain_exactly([3, 'profile::nonexistent'], [4, 'another::missing'])
      end

      it 'does NOT emit for keys whose class does exist' do
        expect(findings.map(&:meta).map { |m| m[:class_name] }).not_to include('profile::base')
      end
    end

    context 'with a namespace-only key that is referenced by an explicit lookup() call' do
      let(:df) do
        Driftless::HieraDataFileInfo.new(
          path: '/tmp/default.yaml',
          top_level_keys: { 'namespace::only::key' => 5 },
        )
      end
      let(:lookup) do
        Driftless::LookupCall.new(key: 'namespace::only::key', file: 'web.pp', line: 10, has_default: false)
      end
      let(:corpus) { hand_corpus(data_files: [df], puppet_classes: {}, code_lookup_calls: [lookup]) }

      it 'exempts the key from missing-class findings' do
        expect(described_class.new(corpus).call).to be_empty
      end
    end

    context 'with data keys that do not use :: (single segment)' do
      let(:df) do
        Driftless::HieraDataFileInfo.new(
          path: '/tmp/default.yaml',
          top_level_keys: { 'simple_key' => 2, 'another' => 3 },
        )
      end
      let(:corpus) { hand_corpus(data_files: [df]) }

      it 'ignores them (not a class::param shape)' do
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
        'detectors' => { 'data:codebase-missing-class' => { 'exclude_classes' => patterns } },
      })
    end

    let(:df) do
      Driftless::HieraDataFileInfo.new(
        path: '/tmp/default.yaml',
        top_level_keys: {
          'profile::legacy::foo' => 2,
          'profile::other::bar'  => 3,
          'role::gone::baz'      => 4,
        },
      )
    end

    let(:classes) { described_class.new(hand_corpus(data_files: [df])).call.map { |f| f.meta[:class_name] } }

    it 'flags every missing class when nothing is excluded' do
      Driftless.config = Driftless::Config.new(merged: {})
      expect(classes).to contain_exactly('profile::legacy', 'profile::other', 'role::gone')
    end

    it 'drops a class named exactly' do
      set_exclusions('profile::legacy')
      expect(classes).to contain_exactly('profile::other', 'role::gone')
    end

    # `*` spans `::`, so one pattern covers a namespace at any depth.
    it 'matches as a glob, with * spanning ::' do
      set_exclusions('profile::*')
      expect(classes).to contain_exactly('role::gone')
    end

    it 'accepts several patterns' do
      set_exclusions('profile::legacy', 'role::*')
      expect(classes).to contain_exactly('profile::other')
    end

    it 'leaves findings alone when the pattern matches nothing' do
      set_exclusions('nothing::here')
      expect(classes.size).to eq(3)
    end
  end
end
