require 'spec_helper'
require 'json'
require 'tmpdir'

require 'driftless/site/build_data'

RSpec.describe Driftless::Site::BuildData do
  def session(collector, session_id)
    { 'collector' => collector, 'session_id' => session_id, 'reports' => ['all-active-nodes'] }
  end

  # A scan document as ScanData.assemble shapes it; hand-made so this spec
  # pins the contract rather than the producer.
  def scan_doc(**overrides)
    {
      'document' => 'scan', 'schema_version' => 1,
      'generated_at' => '2026-08-26T11:00:00Z', 'driftless_version' => '0.2.0',
      'repo' => { 'dir' => '/srv/repo', 'git' => nil },
      'environments' => ['production'],
      'overrides' => { 'accept_partial_report_sessions' => nil, 'accept_duplicate_certnames' => false,
                       'allow_missing_envs' => false },
      'sessions' => [session('east', 'T02'), session('west', 'T01')],
      'nodes' => { 'total' => 2, 'by_collector' => { 'east' => 1, 'west' => 1 }, 'by_environment' => { 'production' => 2 } },
      'findings' => [{ 'key' => 'data:missing-nodes', 'severity' => 'warning', 'quality' => nil,
                       'path' => 'x.yaml', 'line' => nil, 'message' => 'gone', 'meta' => {} }],
      'warnings' => ['w']
    }.merge(overrides)
  end

  def report_doc(**overrides)
    {
      'document' => 'report', 'schema_version' => 1,
      'generated_at' => '2026-08-26T11:05:00Z', 'driftless_version' => '0.2.0',
      'sessions' => [session('east', 'T02'), session('west', 'T01')],
      'utilization' => { 'modules' => [{ 'name' => 'nginx', 'nodes' => 2 }] }
    }.merge(overrides)
  end

  let(:now) { Time.utc(2026, 8, 26, 12, 0, 0) }

  describe '.assemble from a scan document alone' do
    subject(:data) { described_class.assemble(scan: scan_doc, now: now) }

    it 'names its document kind and schema version first' do
      expect(data.keys.first(2)).to eq(%w[document schema_version])
      expect(data).to include('document' => 'site', 'schema_version' => 1)
    end

    it 'stamps itself and records when each source was written' do
      expect(data['generated_at']).to eq('2026-08-26T12:00:00Z')
      expect(data['driftless_version']).to eq(Driftless::VERSION)
      expect(data['sources']).to eq(
        'scan'   => { 'generated_at' => '2026-08-26T11:00:00Z', 'driftless_version' => '0.2.0' },
        'report' => nil,
      )
    end

    it 'carries the scan fields through unchanged' do
      %w[repo environments overrides sessions nodes findings warnings].each do |k|
        expect(data[k]).to eq(scan_doc[k]), k
      end
    end

    it 'leaves utilization null' do
      expect(data).to include('utilization' => nil)
    end
  end

  describe '.assemble with a report document' do
    it 'takes utilization from the report and stamps it as a source' do
      data = described_class.assemble(scan: scan_doc, report: report_doc, now: now)
      expect(data['utilization']).to eq('modules' => [{ 'name' => 'nginx', 'nodes' => 2 }])
      expect(data['sources']['report']['generated_at']).to eq('2026-08-26T11:05:00Z')
    end

    it 'refuses when the two read different sessions, naming the difference' do
      report = report_doc('sessions' => [session('east', 'T03'), session('west', 'T01')])
      expect { described_class.assemble(scan: scan_doc, report: report) }
        .to raise_error(Driftless::JsonDocument::Error,
                        'scan and report data disagree on sessions: scan read east@T02, report read east@T03')
    end

    it 'refuses when one read a collector the other did not' do
      report = report_doc('sessions' => [session('east', 'T02')])
      expect { described_class.assemble(scan: scan_doc, report: report) }
        .to raise_error(Driftless::JsonDocument::Error, /scan read west@T01, report read nothing the other did not/)
    end

    it 'ignores session order' do
      report = report_doc('sessions' => [session('west', 'T01'), session('east', 'T02')])
      expect { described_class.assemble(scan: scan_doc, report: report) }.not_to raise_error
    end
  end

  describe '.write and .read' do
    it 'round-trips through a file' do
      Dir.mktmpdir do |dir|
        data = described_class.assemble(scan: scan_doc, now: now)
        path = described_class.write(data, File.join(dir, 'data.json'))
        expect(described_class.read(path)).to eq(data)
      end
    end

    it 'refuses a scan document' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'scan.json')
        File.write(path, JSON.generate(scan_doc))
        expect { described_class.read(path) }
          .to raise_error(Driftless::JsonDocument::Error, /is a "scan" document, expected "site"/)
      end
    end
  end
end
