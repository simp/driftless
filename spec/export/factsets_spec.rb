require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'

require 'driftless/export/factsets'

RSpec.describe Driftless::Export::Factsets do
  # Layout matches Inputs::ReportLoader expectations:
  # <incoming>/factsets-for-all-active-nodes/<contributor>--<timestamp>.ndjson
  def seed_factsets(incoming_dir, records)
    dir = File.join(incoming_dir, 'factsets-for-all-active-nodes')
    FileUtils.mkdir_p(dir)
    File.write(
      File.join(dir, 'coll--2026-08-14T00-00-00Z.ndjson'),
      records.map { |r| JSON.generate(r) }.join("\n") + "\n",
    )
  end

  def record(certname, facts, environment: 'production', trusted: {})
    {
      'certname'           => certname,
      'catalog_environment'=> environment,
      'facts'              => facts,
      'trusted'            => trusted,
      'report_timestamp'   => '2026-08-14T00:00:00Z',
    }
  end

  it 'writes one file per certname' do
    Dir.mktmpdir do |tmp|
      seed_factsets(tmp, [
        record('web01.example.com', { 'kernel' => 'Linux' }),
        record('db01.example.com',  { 'kernel' => 'Linux' }),
      ])
      out = File.join(tmp, 'out')

      result = described_class.new(
        incoming_dir: tmp, output_dir: out, profile: 'onceover',
      ).run

      expect(result.written).to eq(2)
      expect(Dir.children(out).sort).to eq(%w[db01.example.com.json web01.example.com.json])
    end
  end

  describe 'profile: onceover' do
    it 'emits raw facts as JSON by default' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [
          record('web01.example.com', { 'kernel' => 'Linux', 'os' => { 'family' => 'RedHat' } }),
        ])
        out = File.join(tmp, 'out')

        described_class.new(incoming_dir: tmp, output_dir: out, profile: 'onceover').run

        path = File.join(out, 'web01.example.com.json')
        data = JSON.parse(File.read(path))
        expect(data).to eq('kernel' => 'Linux', 'os' => { 'family' => 'RedHat' })
        expect(data).not_to have_key('hostname')
        expect(data).not_to have_key('clientcert')
      end
    end

    it 'emits YAML when serialization is overridden' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [record('web01.example.com', { 'kernel' => 'Linux' })])
        out = File.join(tmp, 'out')

        described_class.new(
          incoming_dir: tmp, output_dir: out, profile: 'onceover', serialization: 'yaml',
        ).run

        path = File.join(out, 'web01.example.com.yaml')
        expect(YAML.safe_load(File.read(path))).to eq('kernel' => 'Linux')
      end
    end

    it 'does not synthesize identity facts' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [record('web01.example.com', {})])
        out = File.join(tmp, 'out')
        described_class.new(incoming_dir: tmp, output_dir: out, profile: 'onceover').run

        data = JSON.parse(File.read(File.join(out, 'web01.example.com.json')))
        expect(data).to eq({})
      end
    end
  end

  describe 'profile: lookup' do
    it 'emits YAML by default' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [record('web01.example.com', { 'kernel' => 'Linux' })])
        out = File.join(tmp, 'out')

        described_class.new(incoming_dir: tmp, output_dir: out, profile: 'lookup').run

        expect(File).to exist(File.join(out, 'web01.example.com.yaml'))
      end
    end

    it 'synthesizes hostname/domain/fqdn/clientcert from networking.* when absent' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [
          record('web01.example.com', {
            'kernel' => 'Linux',
            'networking' => {
              'hostname' => 'web01',
              'domain'   => 'example.com',
              'fqdn'     => 'web01.example.com',
            },
          }),
        ])
        out = File.join(tmp, 'out')

        described_class.new(incoming_dir: tmp, output_dir: out, profile: 'lookup').run

        data = YAML.safe_load(File.read(File.join(out, 'web01.example.com.yaml')))
        expect(data['hostname']).to eq('web01')
        expect(data['domain']).to eq('example.com')
        expect(data['fqdn']).to eq('web01.example.com')
        expect(data['clientcert']).to eq('web01.example.com')
      end
    end

    it 'falls back to certname split when networking.* is missing' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [record('web01.example.com', { 'kernel' => 'Linux' })])
        out = File.join(tmp, 'out')

        described_class.new(incoming_dir: tmp, output_dir: out, profile: 'lookup').run

        data = YAML.safe_load(File.read(File.join(out, 'web01.example.com.yaml')))
        expect(data['hostname']).to eq('web01')
        expect(data['domain']).to eq('example.com')
        expect(data['fqdn']).to eq('web01.example.com')
        expect(data['clientcert']).to eq('web01.example.com')
      end
    end

    it 'leaves existing top-level identity facts alone' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [
          record('web01.example.com', {
            'hostname'   => 'preexisting-host',
            'domain'     => 'preexisting.example.org',
            'fqdn'       => 'preexisting-host.preexisting.example.org',
            'clientcert' => 'preexisting-clientcert',
          }),
        ])
        out = File.join(tmp, 'out')

        described_class.new(incoming_dir: tmp, output_dir: out, profile: 'lookup').run

        data = YAML.safe_load(File.read(File.join(out, 'web01.example.com.yaml')))
        expect(data['hostname']).to   eq('preexisting-host')
        expect(data['domain']).to     eq('preexisting.example.org')
        expect(data['fqdn']).to       eq('preexisting-host.preexisting.example.org')
        expect(data['clientcert']).to eq('preexisting-clientcert')
      end
    end

    it 'sets domain to empty string when certname is a bare hostname' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [record('bare-host', { 'kernel' => 'Linux' })])
        out = File.join(tmp, 'out')

        described_class.new(incoming_dir: tmp, output_dir: out, profile: 'lookup').run

        data = YAML.safe_load(File.read(File.join(out, 'bare-host.yaml')))
        expect(data['hostname']).to eq('bare-host')
        expect(data['domain']).to   eq('')
        expect(data['fqdn']).to     eq('bare-host')
      end
    end
  end

  describe '--certname glob filter' do
    it 'exports only matching certnames' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [
          record('web01.example.com', {}),
          record('web02.example.com', {}),
          record('db01.example.com',  {}),
        ])
        out = File.join(tmp, 'out')

        result = described_class.new(
          incoming_dir: tmp, output_dir: out, profile: 'onceover',
          certname_globs: ['web*.example.com'],
        ).run

        expect(result.written).to eq(2)
        expect(Dir.children(out).sort).to eq(%w[web01.example.com.json web02.example.com.json])
      end
    end

    it 'unions multiple globs' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [
          record('web01.example.com', {}),
          record('db01.example.com',  {}),
          record('api01.example.com', {}),
        ])
        out = File.join(tmp, 'out')

        result = described_class.new(
          incoming_dir: tmp, output_dir: out, profile: 'onceover',
          certname_globs: ['web*', 'db*'],
        ).run

        expect(result.written).to eq(2)
        expect(Dir.children(out).sort).to eq(%w[db01.example.com.json web01.example.com.json])
      end
    end
  end

  describe '--limit' do
    it 'caps output after filter, sorted by certname' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [
          record('web03.example.com', {}),
          record('web01.example.com', {}),
          record('web02.example.com', {}),
        ])
        out = File.join(tmp, 'out')

        result = described_class.new(
          incoming_dir: tmp, output_dir: out, profile: 'onceover', limit: 2,
        ).run

        expect(result.written).to eq(2)
        expect(Dir.children(out).sort).to eq(%w[web01.example.com.json web02.example.com.json])
      end
    end
  end

  describe 'error cases' do
    it 'raises Error when the factsets report is missing' do
      Dir.mktmpdir do |tmp|
        expect {
          described_class.new(
            incoming_dir: tmp, output_dir: File.join(tmp, 'out'), profile: 'onceover',
          ).run
        }.to raise_error(Driftless::Export::Error, /no report:factsets-for-all-active-nodes data/)
      end
    end

    it 'rejects an unknown profile' do
      expect {
        described_class.new(incoming_dir: '/x', output_dir: '/y', profile: 'bogus')
      }.to raise_error(Driftless::Export::Error, /unknown profile/)
    end

    it 'rejects an unknown serialization' do
      expect {
        described_class.new(incoming_dir: '/x', output_dir: '/y', profile: 'onceover', serialization: 'xml')
      }.to raise_error(Driftless::Export::Error, /unknown serialization/)
    end
  end
end
