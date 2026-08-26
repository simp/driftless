require 'spec_helper'
require 'tmpdir'
require 'fileutils'

require 'driftless/config'

RSpec.describe Driftless::Config do
  # Each test isolates its own home + CWD + system-path via ENV/Dir manipulation.
  # An `around` per-test would work; the manual pattern here is more explicit.

  def with_isolated_env(&_block)
    original_xdg  = ENV['XDG_CONFIG_HOME']
    original_cwd  = Dir.pwd
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |cwd|
        ENV['XDG_CONFIG_HOME'] = home
        Dir.chdir(cwd) do
          yield home: home, cwd: cwd
        end
      end
    end
  ensure
    ENV['XDG_CONFIG_HOME'] = original_xdg
    Dir.chdir(original_cwd) if original_cwd
  end

  def write_user_config(home, content)
    dir = File.join(home, 'driftless')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'config.yaml'), content)
  end

  def write_project_config(cwd, content)
    File.write(File.join(cwd, 'driftless.yaml'), content)
  end

  describe '.load' do
    context 'with no config files anywhere' do
      it 'returns an empty config' do
        with_isolated_env do
          cfg = described_class.load
          expect(cfg).to be_empty
          expect(cfg.sources).to be_empty
        end
      end
    end

    context 'with only a project-local config' do
      it 'loads it as the sole source' do
        with_isolated_env do |cwd:, **|
          write_project_config(cwd, "detectors:\n  defaults:\n    enabled: true\n")
          cfg = described_class.load
          expect(cfg.dig('detectors', 'defaults', 'enabled')).to be(true)
          expect(cfg.sources).to eq([File.join(cwd, 'driftless.yaml')])
        end
      end
    end

    context 'with only a user config (via XDG_CONFIG_HOME)' do
      it 'loads from ~/.config/driftless/config.yaml equivalent' do
        with_isolated_env do |home:, **|
          write_user_config(home, "output:\n  format: json\n")
          cfg = described_class.load
          expect(cfg.dig('output', 'format')).to eq('json')
        end
      end
    end

    context 'with both user and project configs, overlapping scalars' do
      it 'later (project) wins for scalars' do
        with_isolated_env do |home:, cwd:|
          write_user_config(home, "output:\n  format: json\n")
          write_project_config(cwd, "output:\n  format: text\n")
          cfg = described_class.load
          expect(cfg.dig('output', 'format')).to eq('text')
        end
      end

      it 'unions arrays across sources' do
        with_isolated_env do |home:, cwd:|
          write_user_config(home, "detectors:\n  defaults:\n    exclude_paths:\n      - modules/**\n")
          write_project_config(cwd, "detectors:\n  defaults:\n    exclude_paths:\n      - vendor/**\n")
          cfg = described_class.load
          expect(cfg.dig('detectors', 'defaults', 'exclude_paths'))
            .to contain_exactly('modules/**', 'vendor/**')
        end
      end

      it 'deep-merges nested hashes rather than replacing wholesale' do
        with_isolated_env do |home:, cwd:|
          write_user_config(home,    "detectors:\n  defaults:\n    enabled: true\n")
          write_project_config(cwd, "detectors:\n  defaults:\n    exclude_paths: [modules/**]\n")
          cfg = described_class.load
          expect(cfg.dig('detectors', 'defaults', 'enabled')).to be(true)
          expect(cfg.dig('detectors', 'defaults', 'exclude_paths')).to eq(['modules/**'])
        end
      end

      it 'records the sources that contributed, in load order' do
        with_isolated_env do |home:, cwd:|
          write_user_config(home,    "a: 1\n")
          write_project_config(cwd, "b: 2\n")
          cfg = described_class.load
          expect(cfg.sources).to eq([
            File.join(home, 'driftless', 'config.yaml'),
            File.join(cwd,  'driftless.yaml'),
          ])
        end
      end
    end

    context 'with --config=PATH' do
      it 'uses only that file, replacing the chain' do
        with_isolated_env do |home:, cwd:|
          write_user_config(home,    "a: from-user\n")
          write_project_config(cwd, "a: from-project\n")

          override = File.join(cwd, 'ci.yaml')
          File.write(override, "a: from-override\n")

          cfg = described_class.load(config_path: override)
          expect(cfg['a']).to eq('from-override')
          expect(cfg.sources).to eq([override])
        end
      end

      it 'raises if the explicit path does not exist' do
        # NB: implicit search paths silently skip missing files; explicit --config does not.
        # (Verified by looking at discover_sources — implicit paths use File.file?; explicit
        # skips that guard, so File.read raises ENOENT which we convert to ConfigLoadError.)
        with_isolated_env do
          expect { described_class.load(config_path: '/no/such/file.yaml') }
            .to raise_error(Driftless::ConfigLoadError, /file not found/)
        end
      end
    end

    context 'with --no-config' do
      it 'returns empty even when files exist on disk' do
        with_isolated_env do |home:, cwd:|
          write_user_config(home,    "a: 1\n")
          write_project_config(cwd, "b: 2\n")
          cfg = described_class.load(no_config: true)
          expect(cfg).to be_empty
          expect(cfg.sources).to be_empty
        end
      end
    end

    context 'with edge-case file contents' do
      it 'treats an empty file as an empty hash (not nil)' do
        with_isolated_env do |cwd:, **|
          write_project_config(cwd, "")
          cfg = described_class.load
          expect(cfg).to be_empty
          expect(cfg.sources.size).to eq(1)  # still counted as a source
        end
      end

      it 'raises on malformed YAML' do
        with_isolated_env do |cwd:, **|
          write_project_config(cwd, "not: valid: yaml:\n  [\n")
          expect { described_class.load }
            .to raise_error(Driftless::ConfigLoadError, /invalid YAML/)
        end
      end

      it 'raises when top-level YAML is not a mapping (e.g. a bare string)' do
        with_isolated_env do |cwd:, **|
          write_project_config(cwd, "just a string\n")
          expect { described_class.load }
            .to raise_error(Driftless::ConfigLoadError, /top-level YAML must be a mapping/)
        end
      end
    end

    context 'with XDG_CONFIG_HOME unset' do
      it 'defaults the user path to ~/.config/driftless/config.yaml' do
        original = ENV.delete('XDG_CONFIG_HOME')
        expect(described_class.user_path).to eq(File.expand_path('~/.config/driftless/config.yaml'))
      ensure
        ENV['XDG_CONFIG_HOME'] = original if original
      end
    end
  end

  describe 'the loaded Config instance' do
    it 'is deeply frozen (readers cannot mutate)' do
      with_isolated_env do |cwd:, **|
        write_project_config(cwd, "arr: [1, 2]\nnested: {a: 1}\n")
        cfg = described_class.load
        expect(cfg.to_h).to be_frozen
        expect(cfg['arr']).to be_frozen
        expect(cfg['nested']).to be_frozen
      end
    end

    it 'supports hash-like access via [], dig, fetch' do
      with_isolated_env do |cwd:, **|
        write_project_config(cwd, "detectors:\n  defaults:\n    enabled: true\n")
        cfg = described_class.load
        expect(cfg['detectors']).to be_a(Hash)
        expect(cfg.dig('detectors', 'defaults', 'enabled')).to be(true)
        expect(cfg.fetch('missing', :default)).to eq(:default)
      end
    end
  end

  describe 'Driftless.config module accessor' do
    around do |ex|
      original = Driftless.instance_variable_get(:@config)
      ex.run
    ensure
      Driftless.instance_variable_set(:@config, original)
    end

    it 'defaults to an empty Config if never assigned' do
      Driftless.instance_variable_set(:@config, nil)
      expect(Driftless.config).to be_a(described_class)
      expect(Driftless.config).to be_empty
    end

    it 'accepts a Config assignment' do
      loaded = described_class.new(merged: { 'foo' => 'bar' })
      Driftless.config = loaded
      expect(Driftless.config['foo']).to eq('bar')
    end
  end
end
