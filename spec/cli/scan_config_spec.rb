require 'spec_helper'
require 'driftless/cli/scan'

# Focused coverage for Scan's config-derived defaults.
# The broader Scan#execute integration (with real fixtures) lives in
# spec/scan_spec.rb; this file only exercises the @options-population
# precedence order, which resolves once the command's own flags are parsed.
RSpec.describe Driftless::CLI::Scan do
  around do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  def set_config(hash)
    Driftless.config = Driftless::Config.new(merged: hash)
  end

  # Config defaults land in after_own_parse, so stop just short of #execute.
  def opts_after_parse(argv = [], **parent)
    cmd = described_class.new(parent_options: parent)
    cmd.send(:parse_own_options!, argv.dup)
    cmd.after_own_parse
    cmd.instance_variable_get(:@options)
  end

  describe 'config-derived defaults with no CLI flags and no inherited options' do
    it 'reads scan.fail_on' do
      set_config('scan' => { 'fail_on' => 'never' })
      expect(opts_after_parse[:fail_on]).to eq('never')
    end

    it 'reads output.format' do
      set_config('output' => { 'format' => 'json' })
      expect(opts_after_parse[:format]).to eq('json')
    end

    it 'reads output.default_file as :output_file' do
      set_config('output' => { 'default_file' => '/tmp/out.json' })
      expect(opts_after_parse[:output_file]).to eq('/tmp/out.json')
    end

    it 'reads detectors.only and detectors.skip as arrays' do
      set_config('detectors' => { 'only' => ['a', 'b'], 'skip' => ['c'] })
      opts = opts_after_parse
      expect(opts[:only]).to eq(['a', 'b'])
      expect(opts[:skip]).to eq(['c'])
    end

    it 'reads reports.incoming_dir' do
      set_config('reports' => { 'incoming_dir' => '/repo/raw_reports' })
      expect(opts_after_parse[:incoming_dir]).to eq('/repo/raw_reports')
    end

    it 'reads puppet.environments as the environments list' do
      set_config('puppet' => { 'environments' => ['production', 'staging'] })
      expect(opts_after_parse[:environments]).to eq(['production', 'staging'])
    end

    it 'reads puppet.allow_missing_envs' do
      set_config('puppet' => { 'allow_missing_envs' => true })
      expect(opts_after_parse[:allow_missing_envs]).to be(true)
    end
  end

  describe 'precedence: CLI > parent_options > config > hardcoded' do
    it 'hardcoded default (fail_on: any) wins when nothing else is set' do
      set_config({})
      expect(opts_after_parse[:fail_on]).to eq('any')
    end

    it 'config value overrides hardcoded default' do
      set_config('scan' => { 'fail_on' => 'never' })
      expect(opts_after_parse[:fail_on]).to eq('never')
    end

    it 'parent_options overrides config' do
      set_config('scan' => { 'fail_on' => 'never' })
      expect(opts_after_parse([], fail_on: 'any')[:fail_on]).to eq('any')
    end
  end
end
