require 'spec_helper'
require 'driftless/detectors/callable'

RSpec.describe Driftless::Detectors::Callable do
  let(:corpus) { build_corpus }

  # Declaring a key registers the class. Every subclass here declares #call,
  # since Scan runs whatever it finds in the registry answering callable?.
  let(:test_detector_class) do
    Class.new(described_class) do
      key 'test:callable-example'
      about 'test detector for callable specs'
      def call; []; end
    end
  end

  describe '.callable?' do
    it 'is true, so Scan selects it' do
      expect(test_detector_class).to be_callable
    end

    it 'keeps Callable itself out of the registry (it declares no key)' do
      expect(Driftless::Detectors.registry).not_to include(described_class)
    end
  end

  describe '#call' do
    it 'raises NotImplementedError when a subclass does not define it' do
      # No key: an unregistered class stays out of Scan's reach.
      klass = Class.new(described_class)
      expect { klass.new(corpus).call }
        .to raise_error(NotImplementedError, /must implement #call/)
    end
  end

  describe '#corpus' do
    it 'exposes the corpus it was built with' do
      expect(test_detector_class.new(corpus).corpus).to equal(corpus)
    end
  end

  describe 'inherited from Registration' do
    it 'resolves universal options without any per-class declaration' do
      expect(test_detector_class.new(corpus).option(:enabled)).to be(true)
    end
  end

  describe '#meta_finding — severity/quality propagation' do
    let(:tagged_class) do
      Class.new(described_class) do
        key      'test:tagged-meta'
        severity :error
        quality  :wrong
        def call; []; end
      end
    end

    it 'inherits severity + quality from the emitting class defaults' do
      f = tagged_class.new(corpus).send(:meta_finding, key: 'other:key', message: 'x')
      expect(f.severity).to eq(:error)
      expect(f.quality).to eq(:wrong)
    end
  end

  describe '#skip_meta_finding' do
    it 'emits :note severity regardless of the class defaults' do
      klass = Class.new(described_class) do
        key      'test:skip'
        severity :error
        quality  :wrong
        def call; []; end
      end
      f = klass.new(corpus).send(:skip_meta_finding, reason: 'no data')
      expect(f.severity).to eq(:note)
      expect(f.quality).to be_nil
    end
  end

  describe '.requires_reports' do
    it 'defaults to an empty list' do
      expect(test_detector_class.requires_reports).to eq([])
    end

    it 'stores declared report names as strings' do
      # No key, so this does not join the union Detectors.expected_reports takes.
      klass = Class.new(described_class) do
        requires_reports :factsets_for_all_active_nodes
      end
      expect(klass.requires_reports).to eq(['factsets_for_all_active_nodes'])
    end
  end
end
