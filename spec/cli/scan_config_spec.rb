require 'spec_helper'
require 'driftless/cli/scan'

# Focused coverage for Scan's config-derived defaults (chunk 7 of Phase 3).
# The broader Scan#execute integration (with real fixtures) lives in
# spec/scan_spec.rb; this file only exercises the @options-population
# precedence order at construction time.
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

  def opts_after_construct(**parent)
    described_class.new(parent_options: parent).instance_variable_get(:@options)
  end

  describe 'config-derived defaults with no CLI flags and no inherited options' do
    it 'reads scan.fail_on' do
      set_config('scan' => { 'fail_on' => 'never' })
      expect(opts_after_construct[:fail_on]).to eq('never')
    end

    it 'reads output.format' do
      set_config('output' => { 'format' => 'json' })
      expect(opts_after_construct[:format]).to eq('json')
    end

    it 'reads output.default_file as :output_file' do
      set_config('output' => { 'default_file' => '/tmp/out.json' })
      expect(opts_after_construct[:output_file]).to eq('/tmp/out.json')
    end

    it 'reads detectors.only and detectors.skip as arrays' do
      set_config('detectors' => { 'only' => ['a', 'b'], 'skip' => ['c'] })
      opts = opts_after_construct
      expect(opts[:only]).to eq(['a', 'b'])
      expect(opts[:skip]).to eq(['c'])
    end

    it 'reads scan.incoming_dir' do
      set_config('scan' => { 'incoming_dir' => '/repo/raw_reports' })
      expect(opts_after_construct[:incoming_dir]).to eq('/repo/raw_reports')
    end

    it 'accepts puppet.basemodulepath as a colon-separated string' do
      set_config('puppet' => { 'basemodulepath' => '/a:/b:/c' })
      expect(opts_after_construct[:basemodulepath]).to eq(['/a', '/b', '/c'])
    end

    it 'accepts puppet.basemodulepath as an array' do
      set_config('puppet' => { 'basemodulepath' => ['/a', '/b'] })
      expect(opts_after_construct[:basemodulepath]).to eq(['/a', '/b'])
    end
  end

  describe 'precedence: CLI > parent_options > config > hardcoded' do
    it 'hardcoded default (fail_on: any) wins when nothing else is set' do
      set_config({})
      expect(opts_after_construct[:fail_on]).to eq('any')
    end

    it 'config value overrides hardcoded default' do
      set_config('scan' => { 'fail_on' => 'never' })
      expect(opts_after_construct[:fail_on]).to eq('never')
    end

    it 'parent_options overrides config' do
      set_config('scan' => { 'fail_on' => 'never' })
      expect(opts_after_construct(fail_on: 'any')[:fail_on]).to eq('any')
    end
  end
end
