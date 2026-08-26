require 'spec_helper'
require 'driftless/detectors/registration'

RSpec.describe Driftless::Detectors::Registration do
  # Save/restore process-global Driftless.config around every example.
  around(:each) do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  def set_config(hash)
    Driftless.config = Driftless::Config.new(merged: hash)
  end

  # Anonymous subclass under test. Declaring a key registers it into
  # Detectors.registry (harmless in specs: the registry is process-global, and
  # Scan only runs the entries that answer callable?).
  let(:test_registration_class) do
    Class.new(described_class) do
      key 'test:example'
      about 'test registration for DSL specs'
      config_option :my_bool, type: :boolean, default: false
      config_option :my_str,  type: :string,  default: 'default-value'
      config_option :my_arr,  type: :array,   default: []
      config_option :my_re,   type: :regexp,  default: /\Adefault::/
    end
  end

  let(:instance) { test_registration_class.new }

  describe '.key' do
    it 'registers the class that declares it' do
      klass = Class.new(described_class) { key 'test:registers' }
      expect(Driftless::Detectors.registry).to include(klass)
    end

    it 'leaves a subclass that declares no key out of the registry' do
      klass = Class.new(described_class)
      expect(Driftless::Detectors.registry).not_to include(klass)
    end

    it 'keeps Registration itself out of the registry' do
      expect(Driftless::Detectors.registry).not_to include(described_class)
    end
  end

  describe '.callable?' do
    it 'is false: a bare registration is never run by Scan' do
      expect(test_registration_class).not_to be_callable
    end
  end

  describe '.config_option' do
    it 'stores option metadata on the class' do
      expect(test_registration_class.config_options[:my_bool]).to include(
        name: :my_bool, type: :boolean, default: false,
      )
    end

    it 'accepts an `about` description for --verbose rendering' do
      klass = Class.new(described_class) do
        key 'test:with-about'
        config_option :flag, type: :boolean, default: false, about: 'toggles a thing'
      end
      expect(klass.config_options[:flag][:about]).to eq('toggles a thing')
    end
  end

  describe '.config_options' do
    it 'includes universal options inherited from Registration' do
      keys = test_registration_class.config_options.keys
      expect(keys).to include(:enabled, :exclude_paths, :my_bool, :my_str, :my_arr, :my_re)
    end

    it 'has Registration declare :enabled defaulting to true' do
      expect(described_class.config_options[:enabled]).to include(type: :boolean, default: true)
    end

    it 'has Registration declare :exclude_paths defaulting to an empty array' do
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
    it 'reads from the per-key section' do
      set_config('detectors' => { 'test:example' => { 'my_bool' => true } })
      expect(instance.option(:my_bool)).to be(true)
    end

    it 'reads from the defaults section when the per-key section is silent' do
      set_config('detectors' => { 'defaults' => { 'my_str' => 'from-defaults' } })
      expect(instance.option(:my_str)).to eq('from-defaults')
    end

    it 'per-key wins over defaults for scalars' do
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
      end
      set_config('detectors' => { 'test:true-default' => { 'flag' => false } })
      expect(klass.new.option(:flag)).to be(false)
    end
  end

  describe '#option — array union semantics' do
    it 'unions declared-default + defaults section + per-key section' do
      klass = Class.new(described_class) do
        key 'test:arr-default'
        config_option :things, type: :array, default: ['from-declared']
      end
      set_config('detectors' => {
        'defaults'          => { 'things' => ['from-defaults'] },
        'test:arr-default'  => { 'things' => ['from-per-detector'] },
      })
      expect(klass.new.option(:things))
        .to contain_exactly('from-declared', 'from-defaults', 'from-per-detector')
    end

    it 'dedupes overlapping values across sources' do
      set_config('detectors' => {
        'defaults'     => { 'my_arr' => %w[a b] },
        'test:example' => { 'my_arr' => %w[b c] },
      })
      expect(instance.option(:my_arr)).to eq(%w[a b c])
    end

    it 'skips a section that does not set the array (does not concat nil)' do
      set_config('detectors' => { 'defaults' => { 'my_arr' => ['x'] } })
      # per-key section absent for :my_arr
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

    it 'each new instance re-resolves against current config' do
      set_config('detectors' => { 'defaults' => { 'my_str' => 'first' } })
      expect(test_registration_class.new.option(:my_str)).to eq('first')

      set_config('detectors' => { 'defaults' => { 'my_str' => 'second' } })
      expect(test_registration_class.new.option(:my_str)).to eq('second')
    end
  end

  describe '.severity' do
    it 'defaults to :warning when the class does not declare one' do
      expect(test_registration_class.severity).to eq(:warning)
    end

    it 'returns the declared value' do
      klass = Class.new(described_class) do
        key      'test:sev-error'
        severity :error
      end
      expect(klass.severity).to eq(:error)
    end

    it 'raises on an invalid symbol' do
      klass = Class.new(described_class)
      expect { klass.severity(:fatal) }
        .to raise_error(ArgumentError, /invalid severity :fatal/)
    end
  end

  describe '.quality' do
    it 'defaults to nil (unlabelled) when the class does not declare one' do
      expect(test_registration_class.quality).to be_nil
    end

    it 'returns the declared value' do
      klass = Class.new(described_class) do
        key     'test:q-weird'
        quality :weird
      end
      expect(klass.quality).to eq(:weird)
    end

    it 'raises on an invalid symbol' do
      klass = Class.new(described_class)
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
      end
    end

    it 'inherits severity + quality from the class defaults' do
      f = tagged_class.new.send(:build_finding, message: 'x')
      expect(f.severity).to eq(:error)
      expect(f.quality).to eq(:wrong)
    end

    it 'per-finding kwargs override class defaults' do
      f = tagged_class.new
        .send(:build_finding, message: 'x', severity: :warning, quality: :stale)
      expect(f.severity).to eq(:warning)
      expect(f.quality).to eq(:stale)
    end

    it 'falls back to Registration defaults when the class declares neither' do
      # test_registration_class declares neither severity nor quality
      f = instance.send(:build_finding, message: 'x')
      expect(f.severity).to eq(:warning)
      expect(f.quality).to be_nil
    end
  end

  describe 'universal options on Registration' do
    it ':enabled defaults to true when no config is set' do
      expect(instance.option(:enabled)).to be(true)
    end

    it ':exclude_paths defaults to empty array when no config is set' do
      expect(instance.option(:exclude_paths)).to eq([])
    end

    it 'per-key :enabled=false wins over defaults=true' do
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
