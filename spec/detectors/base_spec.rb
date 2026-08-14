require 'spec_helper'
require 'driftless/detectors/base'

RSpec.describe Driftless::Detectors::Base do
  # Save/restore process-global Driftless.config around every example.
  around do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  def set_config(hash)
    Driftless.config = Driftless::Config.new(merged: hash)
  end

  # Anonymous subclass under test. Registered into Detectors.registry as a
  # side effect of subclassing (harmless in specs; the registry is process-
  # global but nothing reads it in tests).
  let(:test_detector_class) do
    Class.new(described_class) do
      key 'test:example'
      about 'test detector for DSL specs'
      config_option :my_bool, type: :boolean, default: false
      config_option :my_str,  type: :string,  default: 'default-value'
      config_option :my_arr,  type: :array,   default: []
      config_option :my_re,   type: :regexp,  default: /\Adefault::/

      def call; []; end
    end
  end

  let(:corpus) { build_corpus }
  let(:instance) { test_detector_class.new(corpus) }

  describe '.config_option' do
    it 'stores option metadata on the class' do
      expect(test_detector_class.config_options[:my_bool]).to include(
        name: :my_bool, type: :boolean, default: false,
      )
    end

    it 'accepts an `about` description for future --verbose rendering' do
      klass = Class.new(described_class) do
        key 'test:with-about'
        config_option :flag, type: :boolean, default: false, about: 'toggles a thing'
        def call; []; end
      end
      expect(klass.config_options[:flag][:about]).to eq('toggles a thing')
    end
  end

  describe '.config_options' do
    it 'includes universal options inherited from Base' do
      keys = test_detector_class.config_options.keys
      expect(keys).to include(:enabled, :exclude_paths, :my_bool, :my_str, :my_arr, :my_re)
    end

    it 'has Base declare :enabled defaulting to true' do
      expect(described_class.config_options[:enabled]).to include(type: :boolean, default: true)
    end

    it 'has Base declare :exclude_paths defaulting to an empty array' do
      expect(described_class.config_options[:exclude_paths]).to include(type: :array, default: [])
    end
  end

  describe '#option — with empty config (declared defaults only)' do
    it 'returns declared default for :boolean' do
      expect(instance.option(:my_bool)).to be(false)
    end

    it 'returns declared default for :string' do
      expect(instance.option(:my_str)).to eq('default-value')
    end

    it 'returns declared default for :array' do
      expect(instance.option(:my_arr)).to eq([])
    end

    it 'returns declared default for :regexp' do
      expect(instance.option(:my_re)).to eq(/\Adefault::/)
    end

    it 'raises ArgumentError for an undeclared option' do
      expect { instance.option(:nonexistent) }
        .to raise_error(ArgumentError, /unknown config option :nonexistent/)
    end
  end

  describe '#option — reads from config' do
    it 'reads from the per-detector section' do
      set_config('detectors' => { 'test:example' => { 'my_bool' => true } })
      expect(instance.option(:my_bool)).to be(true)
    end

    it 'reads from the defaults section when per-detector is silent' do
      set_config('detectors' => { 'defaults' => { 'my_str' => 'from-defaults' } })
      expect(instance.option(:my_str)).to eq('from-defaults')
    end

    it 'per-detector wins over defaults for scalars' do
      set_config('detectors' => {
        'defaults'     => { 'my_str' => 'from-defaults' },
        'test:example' => { 'my_str' => 'from-per-detector' },
      })
      expect(instance.option(:my_str)).to eq('from-per-detector')
    end

    it 'honors boolean false as a real value (does not fall through to default)' do
      klass = Class.new(described_class) do
        key 'test:true-default'
        config_option :flag, type: :boolean, default: true
        def call; []; end
      end
      set_config('detectors' => { 'test:true-default' => { 'flag' => false } })
      expect(klass.new(corpus).option(:flag)).to be(false)
    end
  end

  describe '#option — array union semantics' do
    it 'unions declared-default + defaults section + per-detector section' do
      klass = Class.new(described_class) do
        key 'test:arr-default'
        config_option :things, type: :array, default: ['from-declared']
        def call; []; end
      end
      set_config('detectors' => {
        'defaults'          => { 'things' => ['from-defaults'] },
        'test:arr-default'  => { 'things' => ['from-per-detector'] },
      })
      expect(klass.new(corpus).option(:things))
        .to contain_exactly('from-declared', 'from-defaults', 'from-per-detector')
    end

    it 'dedupes overlapping values across sources' do
      set_config('detectors' => {
        'defaults'     => { 'my_arr' => ['a', 'b'] },
        'test:example' => { 'my_arr' => ['b', 'c'] },
      })
      expect(instance.option(:my_arr)).to eq(['a', 'b', 'c'])
    end

    it 'skips a section that does not set the array (does not concat nil)' do
      set_config('detectors' => { 'defaults' => { 'my_arr' => ['x'] } })
      # per-detector section absent for :my_arr
      expect(instance.option(:my_arr)).to eq(['x'])
    end
  end

  describe '#option — regexp coercion' do
    it 'compiles a string value from config into a Regexp' do
      set_config('detectors' => { 'test:example' => { 'my_re' => '\Afoo::' } })
      re = instance.option(:my_re)
      expect(re).to be_a(Regexp)
      expect('foo::bar').to match(re)
      expect('bar::foo').not_to match(re)
    end

    it 'accepts a Regexp declared-default without re-compiling' do
      expect(instance.option(:my_re)).to eq(/\Adefault::/)
    end
  end

  describe '#option — memoization' do
    it 'memoizes per instance (re-reading config does NOT invalidate a cached call)' do
      first = instance.option(:my_arr)
      set_config('detectors' => { 'defaults' => { 'my_arr' => ['changed'] } })
      # Same instance, cached — returns the previously-cached value
      expect(instance.option(:my_arr)).to equal(first)
    end

    it 'each new detector instance re-resolves against current config' do
      set_config('detectors' => { 'defaults' => { 'my_str' => 'first' } })
      expect(test_detector_class.new(corpus).option(:my_str)).to eq('first')

      set_config('detectors' => { 'defaults' => { 'my_str' => 'second' } })
      expect(test_detector_class.new(corpus).option(:my_str)).to eq('second')
    end
  end

  describe '.severity' do
    it 'defaults to :warning when the class does not declare one' do
      expect(test_detector_class.severity).to eq(:warning)
    end

    it 'returns the declared value' do
      klass = Class.new(described_class) do
        key      'test:sev-error'
        severity :error
        def call; []; end
      end
      expect(klass.severity).to eq(:error)
    end

    it 'raises on an invalid symbol' do
      # Test via post-hoc call rather than class-body DSL: an anonymous
      # subclass that failed mid-declaration would still be in the
      # process-wide registry with no #call defined, breaking scan_spec.
      klass = Class.new(described_class) { def call; []; end }
      expect { klass.severity(:fatal) }
        .to raise_error(ArgumentError, /invalid severity :fatal/)
    end
  end

  describe '.quality' do
    it 'defaults to nil (unlabelled) when the class does not declare one' do
      expect(test_detector_class.quality).to be_nil
    end

    it 'returns the declared value' do
      klass = Class.new(described_class) do
        key     'test:q-weird'
        quality :weird
        def call; []; end
      end
      expect(klass.quality).to eq(:weird)
    end

    it 'raises on an invalid symbol' do
      klass = Class.new(described_class) { def call; []; end }
      expect { klass.quality(:dangerous) }
        .to raise_error(ArgumentError, /invalid quality :dangerous/)
    end
  end

  describe '#build_finding — severity/quality propagation' do
    let(:tagged_class) do
      Class.new(described_class) do
        key      'test:tagged'
        severity :error
        quality  :wrong
        def call; []; end
      end
    end

    it 'inherits severity + quality from the class defaults' do
      f = tagged_class.new(corpus).send(:build_finding, message: 'x')
      expect(f.severity).to eq(:error)
      expect(f.quality).to eq(:wrong)
    end

    it 'per-finding kwargs override class defaults' do
      f = tagged_class.new(corpus)
            .send(:build_finding, message: 'x', severity: :warning, quality: :stale)
      expect(f.severity).to eq(:warning)
      expect(f.quality).to eq(:stale)
    end

    it 'falls back to Base defaults when the class declares neither' do
      # test_detector_class declares neither severity nor quality
      f = instance.send(:build_finding, message: 'x')
      expect(f.severity).to eq(:warning)
      expect(f.quality).to be_nil
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

  describe 'universal options on Base' do
    it ':enabled defaults to true when no config is set' do
      expect(instance.option(:enabled)).to be(true)
    end

    it ':exclude_paths defaults to empty array when no config is set' do
      expect(instance.option(:exclude_paths)).to eq([])
    end

    it 'per-detector :enabled=false wins over defaults=true' do
      set_config('detectors' => { 'test:example' => { 'enabled' => false } })
      expect(instance.option(:enabled)).to be(false)
    end

    it 'universal :exclude_paths accumulates via array union across sources' do
      set_config('detectors' => {
        'defaults'     => { 'exclude_paths' => ['modules/**'] },
        'test:example' => { 'exclude_paths' => ['legacy/**'] },
      })
      expect(instance.option(:exclude_paths))
        .to contain_exactly('modules/**', 'legacy/**')
    end
  end
end
