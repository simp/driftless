require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'

require 'driftless/export/factsets'

RSpec.describe Driftless::Export::Factsets do
  # Layout matches Inputs::ReportLoader expectations:
  # <incoming>/factsets-for-all-active-nodes/<collector>--<timestamp>.ndjson
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
      'certname'            => certname,
      'catalog_environment' => environment,
      'facts'               => facts,
      'trusted'             => trusted,
      'report_timestamp'    => '2026-08-14T00:00:00Z',
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
          selector: Driftless::NodeSelector.new(certname_globs: ['web*.example.com']),
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
          selector: Driftless::NodeSelector.new(certname_globs: ['web*', 'db*']),
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

  describe 'environment filter' do
    let(:records) do
      [
        record('web01.example.com', {}, environment: 'production'),
        record('dev01.example.com', {}, environment: 'dev'),
      ]
    end

    it 'exports every node when no environments are given' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, records)
        out = File.join(tmp, 'out')
        described_class.new(incoming_dir: tmp, output_dir: out, profile: 'onceover').run
        expect(Dir.children(out).sort).to eq(%w[dev01.example.com.json web01.example.com.json])
      end
    end

    it 'drops nodes outside the listed environments' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, records)
        out = File.join(tmp, 'out')
        described_class.new(
          incoming_dir: tmp, output_dir: out, profile: 'onceover', environments: ['production'],
        ).run
        expect(Dir.children(out)).to eq(%w[web01.example.com.json])
      end
    end

    it 'raises ScanError when a configured environment has no reports' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, records)
        exporter = described_class.new(
          incoming_dir: tmp, output_dir: File.join(tmp, 'out'), profile: 'onceover',
          environments: %w[production staging],
        )
        expect { exporter.run }.to raise_error(Driftless::ScanError, /"staging" is configured in puppet.environments/)
      end
    end

    it 'warns instead when proceed_with_subset_of_configured_envs is set' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, records)
        out = File.join(tmp, 'out')
        exporter = described_class.new(
          incoming_dir: tmp, output_dir: out, profile: 'onceover',
          environments: %w[production staging], proceed_with_subset_of_configured_envs: true,
        )
        allow(Driftless.logger).to receive(:warn)
        expect(exporter.run.written).to eq(1)
        expect(exporter.warnings).to contain_exactly(a_string_matching(/"staging" is configured in puppet.environments/))
      end
    end
  end

  describe 'log narration' do
    let(:captured) { StringIO.new }

    around(:each) do |example|
      original_logger = Driftless.logger
      Driftless.logger = Logger.new(captured, level: Logger::DEBUG)
      Driftless.logger.formatter = Driftless::Logging.formatter
      example.run
    ensure
      Driftless.logger = original_logger
    end

    it 'says what was read and written' do
      Dir.mktmpdir do |tmp|
        seed_factsets(tmp, [record('web01.example.com', {})])
        out = File.join(tmp, 'out')

        described_class.new(incoming_dir: tmp, output_dir: out, profile: 'onceover').run

        expect(captured.string).to include("info: factsets: reading #{tmp}")
        expect(captured.string).to include('info: factsets: loaded 1 from coll--2026-08-14T00-00-00Z')
        expect(captured.string).to include("debug: export factsets: wrote #{File.join(out, 'web01.example.com.json')}")
      end
    end
  end

  describe 'error cases' do
    it 'raises ScanError when the factsets report is missing' do
      Dir.mktmpdir do |tmp|
        expect {
          described_class.new(
            incoming_dir: tmp, output_dir: File.join(tmp, 'out'), profile: 'onceover',
          ).run
        }.to raise_error(Driftless::ScanError, /no report:factsets-for-all-active-nodes data/)
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
