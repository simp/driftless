require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'driftless/import/cleanup'

RSpec.describe Driftless::Import::Cleanup do
  # Writes a session's summary to <summary_dir>/<collector>--<sid>.json
  # and each report to <incoming_dir>/<report>/<collector>--<sid>.ndjson.
  # reports: { name => status } — status defaults to 'ok'. Pass status
  # 'failed' to declare failure; pass status 'ok' plus omit_file: true to
  # produce a summary that lies (declared ok, file absent).
  def make_session(incoming_dir:, summary_dir:, collector:, session_id:,
                   reports:, summary_present: true)
    declared = {}
    reports.each do |name, spec|
      spec = { status: 'ok' } if spec.is_a?(Symbol) || spec.is_a?(String) || spec.nil?
      status = spec[:status] || 'ok'
      omit_file = spec[:omit_file] || false

      declared[name] = { 'file' => "#{name}.ndjson", 'status' => status }

      next if omit_file
      dst_dir = File.join(incoming_dir, name)
      FileUtils.mkdir_p(dst_dir)
      File.write(File.join(dst_dir, "#{collector}--#{session_id}.ndjson"),
                 %({"certname":"n"}\n))
    end

    return unless summary_present
    FileUtils.mkdir_p(summary_dir)
    File.write(
      File.join(summary_dir, "#{collector}--#{session_id}.json"),
      JSON.pretty_generate('collector' => collector, 'session_id' => session_id, 'reports' => declared),
    )
  end

  def paths(root)
    Dir.glob(File.join(root, '**', '*'))
      .reject { |f| File.directory?(f) }
      .map    { |f| f.sub(%r{\A#{Regexp.escape(root)}/?}, '') }
      .sort
  end

  describe '#run (strict A+, no override)' do
    it 'leaves a lone complete session as live and moves nothing' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: 's1',
                     reports: { 'all-active-nodes' => nil, 'factsets-for-all-active-nodes' => nil })

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes factsets-for-all-active-nodes],
        ).run

        expect(result.live.map(&:session_id)).to eq(['s1'])
        expect(result.archived).to be_empty
        expect(result.quarantined).to be_empty
        expect(File).to exist(File.join(incoming, 'all-active-nodes', 'alpha--s1.ndjson'))
        expect(File).to exist(File.join(summary, 'alpha--s1.json'))
        expect(File.directory?(File.join(incoming, '.archive'))).to be false
        expect(File.directory?(File.join(incoming, '.quarantine'))).to be false
      end
    end

    it 'archives the older complete session per collector when the newest is complete' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-01-01T00-00-00Z',
                     reports: { 'all-active-nodes' => nil })
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-06-01T00-00-00Z',
                     reports: { 'all-active-nodes' => nil })

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes],
        ).run

        expect(result.live.map(&:session_id)).to eq(['2026-06-01T00-00-00Z'])
        expect(result.archived.map(&:session_id)).to eq(['2026-01-01T00-00-00Z'])
        expect(result.archived.first.reports_moved).to eq(1)
        expect(result.archived.first.summary_moved).to eq(1)

        expect(File).to exist(File.join(incoming, 'all-active-nodes', 'alpha--2026-06-01T00-00-00Z.ndjson'))
        expect(File).to exist(File.join(summary, 'alpha--2026-06-01T00-00-00Z.json'))
        expect(File).not_to exist(File.join(incoming, 'all-active-nodes', 'alpha--2026-01-01T00-00-00Z.ndjson'))
        expect(File).not_to exist(File.join(summary, 'alpha--2026-01-01T00-00-00Z.json'))
        expect(File).to exist(File.join(incoming, '.archive', 'alpha--2026-01-01T00-00-00Z', 'all-active-nodes.ndjson'))
        expect(File).to exist(File.join(incoming, '.archive', 'alpha--2026-01-01T00-00-00Z', '_summary.json'))
      end
    end

    it 'holds each collector independent — one collector superseding does not affect another' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: 's1',
                     reports: { 'all-active-nodes' => nil })
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: 's2',
                     reports: { 'all-active-nodes' => nil })
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'beta', session_id: 's1',
                     reports: { 'all-active-nodes' => nil })

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes],
        ).run

        expect(result.live.map { |s| [s.collector, s.session_id] }).to contain_exactly(
          %w[alpha s2], %w[beta s1],
        )
        expect(result.archived.map { |s| [s.collector, s.session_id] }).to eq([%w[alpha s1]])
      end
    end

    it 'quarantines a session with no _summary.json' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: 's1',
                     reports: { 'all-active-nodes' => nil }, summary_present: false)

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes],
        ).run

        expect(result.live).to be_empty
        expect(result.quarantined.map(&:session_id)).to eq(['s1'])
        expect(result.quarantined.first.reason).to include('no _summary.json')
        expect(File).to exist(File.join(incoming, '.quarantine', 'alpha--s1', 'all-active-nodes.ndjson'))
        expect(File).not_to exist(File.join(incoming, '.quarantine', 'alpha--s1', '_summary.json'))
      end
    end

    it 'quarantines a session whose summary omits an expected report' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: 's1',
                     reports: { 'all-active-nodes' => nil })

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes factsets-for-all-active-nodes],
        ).run

        expect(result.quarantined.map(&:session_id)).to eq(['s1'])
        expect(result.quarantined.first.reason).to match(/factsets-for-all-active-nodes.+not listed/)
      end
    end

    it 'quarantines a session whose summary marks an expected report failed' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: 's1',
                     reports: { 'all-active-nodes' => { status: 'failed', omit_file: true } })

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes],
        ).run

        expect(result.quarantined.map(&:session_id)).to eq(['s1'])
        expect(result.quarantined.first.reason).to include('status "failed"')
      end
    end

    it 'quarantines a session whose summary claims status:ok for a report absent on disk' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: 's1',
                     reports: { 'all-active-nodes' => { status: 'ok', omit_file: true } })

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes],
        ).run

        expect(result.quarantined.map(&:session_id)).to eq(['s1'])
        expect(result.quarantined.first.reason).to include('status:ok but no file')
      end
    end

    it 'quarantines a newer incomplete session and keeps an older complete session live' do
      # Session-atomic supersession: "newest COMPLETE session wins" — so
      # the older complete session is live even though a newer session
      # exists (that newer one quarantines).
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-01-01T00-00-00Z',
                     reports: { 'all-active-nodes' => nil })
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-06-01T00-00-00Z',
                     reports: { 'all-active-nodes' => { status: 'failed', omit_file: true } })

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes],
        ).run

        expect(result.live.map(&:session_id)).to eq(['2026-01-01T00-00-00Z'])
        expect(result.quarantined.map(&:session_id)).to eq(['2026-06-01T00-00-00Z'])
      end
    end

    it 'dry_run leaves the filesystem untouched but reports what would happen' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-01-01T00-00-00Z',
                     reports: { 'all-active-nodes' => nil })
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-06-01T00-00-00Z',
                     reports: { 'all-active-nodes' => nil })

        before_incoming = paths(incoming)
        before_summary  = paths(summary)

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary, dry_run: true,
          expected_reports: %w[all-active-nodes],
        ).run

        expect(result.dry_run).to be true
        expect(result.archived.map(&:session_id)).to eq(['2026-01-01T00-00-00Z'])
        expect(result.archived.first.reports_moved).to eq(1)
        expect(result.archived.first.summary_moved).to eq(1)
        expect(paths(incoming)).to eq(before_incoming)
        expect(paths(summary)).to eq(before_summary)
      end
    end

    it 'moves every on-disk report for a session (not just expected ones)' do
      # Session-atomic: if the session is archived/quarantined, ALL its
      # files move — including reports the operator didn't require.
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-01-01T00-00-00Z',
                     reports: { 'all-active-nodes' => nil, 'extra-report' => nil })
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-06-01T00-00-00Z',
                     reports: { 'all-active-nodes' => nil })

        described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes],
        ).run

        expect(File).to exist(File.join(incoming, '.archive', 'alpha--2026-01-01T00-00-00Z', 'all-active-nodes.ndjson'))
        expect(File).to exist(File.join(incoming, '.archive', 'alpha--2026-01-01T00-00-00Z', 'extra-report.ndjson'))
      end
    end

    it 'raises when incoming_dir or summary_dir is missing/blank' do
      expect { described_class.new(incoming_dir: '', summary_dir: '/tmp/s').run }
        .to raise_error(Driftless::Import::Error, /incoming_dir required/)
      expect { described_class.new(incoming_dir: '/tmp/i', summary_dir: '').run }
        .to raise_error(Driftless::Import::Error, /summary_dir required/)
    end

    it 'is a no-op on empty dirs' do
      Dir.mktmpdir do |tmp|
        result = described_class.new(
          incoming_dir: File.join(tmp, 'incoming'), summary_dir: File.join(tmp, 'summary'),
          expected_reports: %w[all-active-nodes],
        ).run
        expect(result.live).to be_empty
        expect(result.archived).to be_empty
        expect(result.quarantined).to be_empty
      end
    end

    it 'skips dot-prefixed entries when re-scanning an already-cleaned tree (idempotence)' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: 's1',
                     reports: { 'all-active-nodes' => nil })
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: 's2',
                     reports: { 'all-active-nodes' => nil })

        described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes],
        ).run

        # Re-run: .archive/ should not resurface as a "collector" and re-cycle.
        second = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes],
        ).run

        expect(second.live.map(&:session_id)).to eq(['s2'])
        expect(second.archived).to be_empty
        expect(second.quarantined).to be_empty
      end
    end
  end

  describe '#run — bare override (accept_missing_summary + expected=[])' do
    it 'accepts a session with no _summary.json (identity from filename)' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-06-01T00-00-00Z',
                     reports: { 'all-active-nodes' => nil }, summary_present: false)

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: [], accept_missing_summary: true,
        ).run

        expect(result.live.map { |s| [s.collector, s.session_id] })
          .to eq([%w[alpha 2026-06-01T00-00-00Z]])
        expect(result.quarantined).to be_empty
      end
    end

    it 'accepts a session that covers only a subset of what detectors expect' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-06-01T00-00-00Z',
                     reports: { 'all-active-nodes' => nil })  # missing factsets

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: [], accept_missing_summary: true,
        ).run

        expect(result.live.map(&:session_id)).to eq(['2026-06-01T00-00-00Z'])
      end
    end

    it 'still quarantines summary-vs-file mismatch (never overridable)' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-06-01T00-00-00Z',
                     reports: { 'all-active-nodes' => { status: 'ok', omit_file: true } })

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: [], accept_missing_summary: true,
        ).run

        expect(result.live).to be_empty
        expect(result.quarantined.map(&:session_id)).to eq(['2026-06-01T00-00-00Z'])
        expect(result.quarantined.first.reason).to include('status:ok but no file')
      end
    end
  end

  describe '#run — list override (expected_reports=[…], strict summary)' do
    it 'requires exactly the listed reports and ignores what detectors declare' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-06-01T00-00-00Z',
                     reports: { 'all-active-nodes' => nil })  # would be incomplete under real detectors

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes],
        ).run

        expect(result.live.map(&:session_id)).to eq(['2026-06-01T00-00-00Z'])
      end
    end

    it 'still requires _summary.json under list override' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: '2026-06-01T00-00-00Z',
                     reports: { 'all-active-nodes' => nil }, summary_present: false)

        result = described_class.new(
          incoming_dir: incoming, summary_dir: summary,
          expected_reports: %w[all-active-nodes],  # list override; accept_missing_summary defaults false
        ).run

        expect(result.live).to be_empty
        expect(result.quarantined.first.reason).to include('no _summary.json')
      end
    end
  end

  describe '#run — expected-set derivation from registered detectors' do
    it 'derives expected set from Detectors.registry when expected_reports arg is nil' do
      Dir.mktmpdir do |tmp|
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')
        # Real detectors declare 'all-active-nodes', 'factsets-for-all-active-nodes',
        # and 'classes-for-all-active-nodes'.
        make_session(incoming_dir: incoming, summary_dir: summary,
                     collector: 'alpha', session_id: 's1',
                     reports: { 'all-active-nodes' => nil, 'factsets-for-all-active-nodes' => nil,
                                'classes-for-all-active-nodes' => nil })

        result = described_class.new(incoming_dir: incoming, summary_dir: summary).run

        expect(result.live.map(&:session_id)).to eq(['s1'])
        expect(result.quarantined).to be_empty
      end
    end
  end
end
