require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'driftless/import/local'

RSpec.describe Driftless::Import::Local do
  def make_session(session_dir, collector:, session_id:, reports:)
    FileUtils.mkdir_p(session_dir)
    summary = { 'collector' => collector, 'session_id' => session_id, 'reports' => {} }
    reports.each do |name, contents|
      file = "#{name}.ndjson"
      File.write(File.join(session_dir, file), contents)
      summary['reports'][name] = { 'file' => file }
    end
    File.write(File.join(session_dir, '_summary.json'), JSON.pretty_generate(summary))
  end

  describe '#run' do
    it 'imports a session dir into <incoming>/<query>/<collector>--<session>.ndjson' do
      Dir.mktmpdir do |tmp|
        session = File.join(tmp, 'sess-abc')
        make_session(session, collector: 'foo', session_id: 'sess-abc', reports: {
          'all-active-nodes'              => "{\"certname\":\"n1\"}\n",
          'factsets-for-all-active-nodes' => "{\"certname\":\"n1\",\"facts\":{}}\n",
        })
        incoming = File.join(tmp, 'incoming')

        result = described_class.new(incoming_dir: incoming).run(session)

        expect(result.copied).to eq(2)
        expect(result.skipped_missing).to eq(0)
        expect(result.collector).to eq('foo')
        expect(result.session_id).to eq('sess-abc')
        expect(File).to exist(File.join(incoming, 'all-active-nodes', 'foo--sess-abc.ndjson'))
        expect(File).to exist(File.join(incoming, 'factsets-for-all-active-nodes', 'foo--sess-abc.ndjson'))
      end
    end

    it 'discovers the latest session under a reports root' do
      Dir.mktmpdir do |tmp|
        older = File.join(tmp, 'reports', 'sessions', '2026-01-01T00-00-00Z-old')
        newer = File.join(tmp, 'reports', 'sessions', '2026-06-01T00-00-00Z-new')
        make_session(older, collector: 'foo', session_id: '2026-01-01T00-00-00Z-old', reports: { 'all-active-nodes' => "{}\n" })
        make_session(newer, collector: 'foo', session_id: '2026-06-01T00-00-00Z-new', reports: { 'all-active-nodes' => "{}\n" })
        incoming = File.join(tmp, 'incoming')

        result = described_class.new(incoming_dir: incoming).run(File.join(tmp, 'reports'))
        expect(result.session_id).to eq('2026-06-01T00-00-00Z-new')
        expect(File).to exist(File.join(incoming, 'all-active-nodes', 'foo--2026-06-01T00-00-00Z-new.ndjson'))
      end
    end

    it 'honors an explicit session id under a reports root' do
      Dir.mktmpdir do |tmp|
        older = File.join(tmp, 'reports', 'sessions', '2026-01-01T00-00-00Z-old')
        newer = File.join(tmp, 'reports', 'sessions', '2026-06-01T00-00-00Z-new')
        make_session(older, collector: 'foo', session_id: '2026-01-01T00-00-00Z-old', reports: { 'all-active-nodes' => "{}\n" })
        make_session(newer, collector: 'foo', session_id: '2026-06-01T00-00-00Z-new', reports: { 'all-active-nodes' => "{}\n" })
        incoming = File.join(tmp, 'incoming')

        result = described_class.new(incoming_dir: incoming)
          .run(File.join(tmp, 'reports'), session_pref: '2026-01-01T00-00-00Z-old')
        expect(result.session_id).to eq('2026-01-01T00-00-00Z-old')
      end
    end

    it 'dry-run does not touch the filesystem' do
      Dir.mktmpdir do |tmp|
        session = File.join(tmp, 'sess-abc')
        make_session(session, collector: 'foo', session_id: 'sess-abc', reports: { 'all-active-nodes' => "{}\n" })
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')

        result = described_class.new(incoming_dir: incoming, summary_dir: summary, dry_run: true).run(session)
        expect(result.copied).to eq(1)
        expect(result.summary_copied).to eq(1)
        expect(File.directory?(incoming)).to be false
        expect(File.directory?(summary)).to be false
      end
    end

    it 'copies the session summary to <summary-dir>/<collector>--<session>.json' do
      Dir.mktmpdir do |tmp|
        session = File.join(tmp, 'sess-abc')
        make_session(session, collector: 'foo', session_id: 'sess-abc', reports: {
          'all-active-nodes' => "{}\n",
        })
        incoming = File.join(tmp, 'incoming')
        summary  = File.join(tmp, 'summary')

        result = described_class.new(incoming_dir: incoming, summary_dir: summary).run(session)

        expect(result.summary_copied).to eq(1)
        dst = File.join(summary, 'foo--sess-abc.json')
        expect(File).to exist(dst)
        expect(JSON.parse(File.read(dst)).fetch('collector')).to eq('foo')
      end
    end

    it 'omits the summary copy when summary_dir is nil' do
      Dir.mktmpdir do |tmp|
        session = File.join(tmp, 'sess-abc')
        make_session(session, collector: 'foo', session_id: 'sess-abc', reports: { 'all-active-nodes' => "{}\n" })
        incoming = File.join(tmp, 'incoming')

        result = described_class.new(incoming_dir: incoming).run(session)

        expect(result.summary_copied).to eq(0)
        expect(File.directory?(File.join(tmp, 'summary'))).to be false
      end
    end

    it 'rm_after removes the session dir on success (not under dry_run)' do
      Dir.mktmpdir do |tmp|
        session = File.join(tmp, 'sess-abc')
        make_session(session, collector: 'foo', session_id: 'sess-abc', reports: { 'all-active-nodes' => "{}\n" })
        incoming = File.join(tmp, 'incoming')

        described_class.new(incoming_dir: incoming, rm_after: true).run(session)
        expect(File.directory?(session)).to be false
      end
    end

    it 'skips (with count) reports whose file is missing at source' do
      Dir.mktmpdir do |tmp|
        session = File.join(tmp, 'sess-abc')
        make_session(session, collector: 'foo', session_id: 'sess-abc',
                     reports: { 'all-active-nodes' => "{}\n" })
        File.delete(File.join(session, 'all-active-nodes.ndjson'))
        incoming = File.join(tmp, 'incoming')

        result = described_class.new(incoming_dir: incoming).run(session)
        expect(result.copied).to eq(0)
        expect(result.skipped_missing).to eq(1)
      end
    end

    it 'raises Import::Error when source arg is missing' do
      expect { described_class.new(incoming_dir: '/tmp/nope').run(nil) }
        .to raise_error(Driftless::Import::Error, /source path required/)
    end

    it 'raises Import::Error when source is not a directory' do
      expect { described_class.new(incoming_dir: '/tmp/nope').run('/definitely/not/a/real/path') }
        .to raise_error(Driftless::Import::Error, /not a directory/)
    end

    it 'raises Import::Error when a reports root has no sessions/ subdir' do
      Dir.mktmpdir do |tmp|
        expect { described_class.new(incoming_dir: '/tmp/nope').run(tmp) }
          .to raise_error(Driftless::Import::Error, /no _summary\.json/)
      end
    end

    it 'raises Import::Error when a requested session id is not present' do
      Dir.mktmpdir do |tmp|
        sess = File.join(tmp, 'reports', 'sessions', 'a')
        make_session(sess, collector: 'foo', session_id: 'a', reports: { 'all-active-nodes' => "{}\n" })
        expect { described_class.new(incoming_dir: '/tmp/nope').run(File.join(tmp, 'reports'), session_pref: 'b') }
          .to raise_error(Driftless::Import::Error, /session b not found/)
      end
    end

    it 'raises Import::Error on an unparseable _summary.json' do
      Dir.mktmpdir do |tmp|
        FileUtils.mkdir_p(tmp)
        File.write(File.join(tmp, '_summary.json'), '{not json')
        expect { described_class.new(incoming_dir: '/tmp/nope').run(tmp) }
          .to raise_error(Driftless::Import::Error, /invalid _summary\.json/)
      end
    end
  end
end
