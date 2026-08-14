require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'driftless/inputs/summary_index'

RSpec.describe Driftless::Inputs::SummaryIndex do
  def write_summary(dir, collector, session_id, reports)
    File.write(
      File.join(dir, "#{collector}--#{session_id}.json"),
      JSON.generate('collector' => collector, 'session_id' => session_id, 'reports' => reports),
    )
  end

  describe '.latest_per_collector' do
    it 'returns {} when summary_dir is nil' do
      expect(described_class.latest_per_collector(nil)).to eq({})
    end

    it 'returns {} when summary_dir does not exist' do
      expect(described_class.latest_per_collector('/nonexistent/path/here')).to eq({})
    end

    it 'returns {} for an empty directory' do
      Dir.mktmpdir { |dir| expect(described_class.latest_per_collector(dir)).to eq({}) }
    end

    it 'yields one entry per collector' do
      Dir.mktmpdir do |dir|
        write_summary(dir, 'alpha', '2026-01-01T00-00-00Z', { 'all-active-nodes' => { 'status' => 'ok' } })
        write_summary(dir, 'beta',  '2026-01-02T00-00-00Z', { 'all-active-nodes' => { 'status' => 'ok' } })
        result = described_class.latest_per_collector(dir)
        expect(result.keys).to contain_exactly('alpha', 'beta')
      end
    end

    it 'picks the session_id that sorts highest per collector' do
      Dir.mktmpdir do |dir|
        write_summary(dir, 'alpha', '2026-01-01T00-00-00Z', { 'r' => { 'status' => 'ok' } })
        write_summary(dir, 'alpha', '2026-06-01T00-00-00Z', { 'r' => { 'status' => 'failed' } })
        write_summary(dir, 'alpha', '2026-03-01T00-00-00Z', { 'r' => { 'status' => 'ok' } })
        entry = described_class.latest_per_collector(dir).fetch('alpha')
        expect(entry.session_id).to eq('2026-06-01T00-00-00Z')
        expect(entry.reports_declared).to eq('r' => { 'status' => 'failed' })
      end
    end

    it 'ignores dot-prefixed entries' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, '.archive'))
        File.write(File.join(dir, '.hidden.json'), '{"collector":"x","session_id":"y","reports":{}}')
        write_summary(dir, 'alpha', 's1', { 'r' => { 'status' => 'ok' } })
        result = described_class.latest_per_collector(dir)
        expect(result.keys).to eq(['alpha'])
      end
    end

    it 'skips files that fail JSON parse (logging a warning)' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'bad--s1.json'), '{not json')
        write_summary(dir, 'good', 's1', { 'r' => { 'status' => 'ok' } })
        expect(Driftless.logger).to receive(:warn).with(/invalid JSON/)
        result = described_class.latest_per_collector(dir)
        expect(result.keys).to eq(['good'])
      end
    end

    it 'skips filenames without the collector--session_id shape' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'no-separator.json'), '{}')
        write_summary(dir, 'alpha', 's1', { 'r' => { 'status' => 'ok' } })
        result = described_class.latest_per_collector(dir)
        expect(result.keys).to eq(['alpha'])
      end
    end

    it 'exposes reports_declared from the winning summary' do
      Dir.mktmpdir do |dir|
        reports = {
          'all-active-nodes'              => { 'status' => 'ok', 'file' => 'x' },
          'factsets-for-all-active-nodes' => { 'status' => 'failed', 'error' => 'boom' },
        }
        write_summary(dir, 'alpha', 's1', reports)
        entry = described_class.latest_per_collector(dir).fetch('alpha')
        expect(entry.reports_declared).to eq(reports)
      end
    end
  end
end
