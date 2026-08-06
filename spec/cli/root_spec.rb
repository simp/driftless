require 'spec_helper'
require 'tmpdir'
require 'fileutils'

require 'driftless/cli/root'

RSpec.describe Driftless::CLI::Root do
  # Save/restore process-globals around every example.
  around do |ex|
    original_config = Driftless.instance_variable_get(:@config)
    original_level  = Driftless.logger.level
    original_xdg    = ENV['XDG_CONFIG_HOME']
    original_cwd    = Dir.pwd
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original_config)
    Driftless.logger.level = original_level
    ENV['XDG_CONFIG_HOME']  = original_xdg
    Dir.chdir(original_cwd) if original_cwd
  end

  def root_with_options(**opts)
    root = described_class.new
    root.instance_variable_set(:@options, opts)
    root
  end

  describe '#after_own_parse — loading from --config=PATH' do
    it 'loads only the given file, replacing the search chain' do
      Dir.mktmpdir do |dir|
        override = File.join(dir, 'ci.yaml')
        File.write(override, "detectors:\n  defaults:\n    enabled: false\n")
        root_with_options(config_path: override).after_own_parse
        expect(Driftless.config.dig('detectors', 'defaults', 'enabled')).to be(false)
        expect(Driftless.config.sources).to eq([override])
      end
    end

    it 'exits 2 with a clean error when --config path does not exist' do
      expect {
        expect { root_with_options(config_path: '/no/such/file.yaml').after_own_parse }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
      }.to output(/config error:.*file not found/).to_stderr
    end
  end

  describe '#after_own_parse — with --no-config' do
    it 'returns an empty config even when files exist on disk' do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |cwd|
          FileUtils.mkdir_p(File.join(home, 'driftless'))
          File.write(File.join(home, 'driftless', 'config.yaml'), "a: from-user\n")
          File.write(File.join(cwd,  'driftless.yaml'),           "b: from-project\n")
          ENV['XDG_CONFIG_HOME'] = home
          Dir.chdir(cwd) do
            root_with_options(no_config: true).after_own_parse
            expect(Driftless.config).to be_empty
          end
        end
      end
    end
  end

  describe '#after_own_parse — default (no flags)' do
    it 'discovers and merges layered config from user + project' do
      Dir.mktmpdir do |home|
        Dir.mktmpdir do |cwd|
          FileUtils.mkdir_p(File.join(home, 'driftless'))
          File.write(File.join(home, 'driftless', 'config.yaml'), "detectors:\n  defaults:\n    enabled: true\n")
          File.write(File.join(cwd,  'driftless.yaml'),           "output:\n  format: json\n")
          ENV['XDG_CONFIG_HOME'] = home
          Dir.chdir(cwd) do
            root_with_options.after_own_parse
            expect(Driftless.config.dig('detectors', 'defaults', 'enabled')).to be(true)
            expect(Driftless.config.dig('output', 'format')).to eq('json')
          end
        end
      end
    end
  end

  describe 'CLI flag parsing (integration through OptionParser)' do
    it 'parses --config=PATH and stores in @options[:config_path]' do
      root = described_class.new
      root.send(:parse_own_options!, ['-c', '/tmp/foo.yaml', 'help'])
      expect(root.instance_variable_get(:@options)[:config_path]).to eq('/tmp/foo.yaml')
    end

    it 'parses --no-config and stores in @options[:no_config]' do
      root = described_class.new
      root.send(:parse_own_options!, ['--no-config', 'help'])
      expect(root.instance_variable_get(:@options)[:no_config]).to be(true)
    end
  end
end
