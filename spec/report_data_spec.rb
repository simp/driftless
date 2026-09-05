require 'json'
require 'time'
require 'tmpdir'

require 'spec_helper'
require 'driftless/report_data'

RSpec.describe Driftless::ReportData do
  FakeReporter = Struct.new(:reported, :utilization, :accept_partial_report_sessions,
                            :accept_duplicate_certnames, :proceed_with_subset_of_configured_envs,
                            keyword_init: true)

  def reported
    session = Driftless::Reported::Session.new(
      collector: 'east', session_id: 'T01',
      reports: %w[all-active-nodes classes-for-all-active-nodes],
    )
    nodes = [Driftless::Node.new(certname: 'web1', environment: 'production', collector: 'east')]
    Driftless::Reported.new(data: { 'all-active-nodes' => nodes }, sessions: [session])
  end

  def reporter(**overrides)
    FakeReporter.new(**{
      reported:                       reported,
      utilization:                    { 'modules' => [{ 'name' => 'apache', 'nodes' => 1 }] },
      accept_partial_report_sessions: nil,
      accept_duplicate_certnames:     false,
      proceed_with_subset_of_configured_envs: false,
    }, **overrides)
  end

  describe '.assemble' do
    let(:now)  { Time.utc(2026, 9, 1, 12, 0, 0) }
    let(:data) { described_class.assemble(reporter, now: now) }

    it 'names its kind and schema version in the first two keys' do
      expect(data.keys.first(2)).to eq(%w[document schema_version])
      expect(data['document']).to eq('report')
      expect(data['schema_version']).to eq(1)
    end

    it 'stamps generated_at and driftless_version' do
      expect(data['generated_at']).to eq('2026-09-01T12:00:00Z')
      expect(data['driftless_version']).to eq(Driftless::VERSION)
    end

    it 'carries the sessions as the loader read them' do
      expect(data['sessions']).to eq([{
        'collector' => 'east', 'session_id' => 'T01',
        'reports' => %w[all-active-nodes classes-for-all-active-nodes]
      }])
    end

    it 'carries the nodes tally in the scan-document shape' do
      expect(data['nodes']).to eq(
        'total' => 1, 'by_collector' => { 'east' => 1 }, 'by_environment' => { 'production' => 1 },
      )
    end

    it 'carries the overrides in the scan-document shape' do
      expect(data['overrides']).to eq(
        'accept_partial_report_sessions' => nil,
        'accept_duplicate_certnames'     => false,
        'proceed_with_subset_of_configured_envs' => false,
      )
    end

    it 'carries utilization verbatim' do
      expect(data['utilization']).to eq('modules' => [{ 'name' => 'apache', 'nodes' => 1 }])
    end
  end

  describe '.write / .read' do
    it 'round-trips through the document layer' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'report.json')
        data = described_class.assemble(reporter, now: Time.utc(2026, 9, 1))
        described_class.write(data, path)
        expect(described_class.read(path)).to eq(data)
      end
    end

    it 'refuses a document of another kind' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'report.json')
        Driftless::JsonDocument.write({ 'document' => 'scan', 'schema_version' => 1 }, path)
        expect { described_class.read(path) }.to raise_error(Driftless::JsonDocument::Error)
      end
    end
  end
end
