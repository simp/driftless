require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'fileutils'

require 'driftless/scan'

RSpec.describe Driftless::Scan do
  # Save/restore Driftless.config around every example — Scan#run reads it
  # per-detector via option() calls.
  around do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  def set_config(hash)
    Driftless.config = Driftless::Config.new(merged: hash)
  end

  def minimal_repo(dir)
    File.write(File.join(dir, 'hiera.yaml'), <<~YAML)
      ---
      version: 5
      defaults:
        datadir: data
        data_hash: yaml_data
      hierarchy:
        - name: 'Common'
          path: 'common.yaml'
    YAML
    File.write(File.join(dir, 'environment.conf'), "modulepath = site-modules:modules\n")
    FileUtils.mkdir_p(File.join(dir, 'data'))
    FileUtils.mkdir_p(File.join(dir, 'incoming'))
  end

  # Spot-check: confirm scan.rb actually calls Driftless.logger during a run.
  # A single canary test proves the wire between the log-emitter and the logger
  # is intact end-to-end; per-line coverage is deferred until it earns its keep.
  describe 'log narration' do
    around do |example|
      captured        = StringIO.new
      original_logger = Driftless.logger
      Driftless.logger = Logger.new(captured, level: Logger::INFO)
      Driftless.logger.formatter = proc { |sev, _t, _p, msg| "#{sev.downcase}: #{msg}\n" }
      @captured = captured
      example.run
    ensure
      Driftless.logger = original_logger
    end

    it 'emits INFO milestones during a scan against a minimal control repo' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'hiera.yaml'), <<~YAML)
          ---
          version: 5
          defaults:
            datadir: data
            data_hash: yaml_data
          hierarchy:
            - name: 'Common'
              path: 'common.yaml'
        YAML
        File.write(File.join(dir, 'environment.conf'), "modulepath = site-modules:modules\n")
        FileUtils.mkdir_p(File.join(dir, 'data'))
        FileUtils.mkdir_p(File.join(dir, 'incoming'))

        described_class.new(repo_dir: dir, incoming_dir: File.join(dir, 'incoming')).run

        expect(@captured.string).to match(/info: Scanning control repo: /)
        expect(@captured.string).to match(/info: Loaded \d+ hierarchy tiers/)
        expect(@captured.string).to match(/info: Scan complete: \d+ findings/)
      end
    end
  end

  describe 'detector :enabled config' do
    around do |ex|
      captured        = StringIO.new
      original_logger = Driftless.logger
      Driftless.logger = Logger.new(captured, level: Logger::INFO)
      Driftless.logger.formatter = proc { |sev, _t, _p, msg| "#{sev.downcase}: #{msg}\n" }
      @captured = captured
      ex.run
    ensure
      Driftless.logger = original_logger
    end

    it 'skips detectors whose option(:enabled) is false' do
      Dir.mktmpdir do |dir|
        minimal_repo(dir)
        set_config('detectors' => { 'hierarchy:orphaned-paths' => { 'enabled' => false } })

        findings = described_class.new(repo_dir: dir, incoming_dir: File.join(dir, 'incoming')).run

        # No hierarchy:orphaned-paths findings — the detector was skipped.
        expect(findings.map(&:key)).not_to include('hierarchy:orphaned-paths')
        expect(findings.map(&:key)).not_to include('skipped:hierarchy:orphaned-paths')

        # And the log narrates the skip.
        expect(@captured.string).to match(/hierarchy:orphaned-paths → disabled by config/)
      end
    end
  end

  describe 'detector :exclude_paths integration' do
    it 'filters findings whose path matches an exclude pattern' do
      # Construct a corpus + config directly and drive Scan's private helper
      # to test the filter without needing a fixture-generating detector.
      scan = described_class.new(repo_dir: '/tmp/repo', incoming_dir: '/tmp/incoming')

      findings = [
        Driftless::Finding.new(key: 'x', path: '/tmp/repo/modules/apache/manifests/init.pp',
                               line: 1, message: 'a', meta: {}),
        Driftless::Finding.new(key: 'x', path: '/tmp/repo/data/common.yaml',
                               line: 1, message: 'b', meta: {}),
        Driftless::Finding.new(key: 'x', path: nil, line: nil, message: 'structural', meta: {}),
      ]

      result = scan.send(:apply_exclude_paths, findings, ['modules/**'], 'x')

      # modules/... excluded; data/... kept; nil-path kept.
      paths = result.map(&:path)
      expect(paths).to contain_exactly('/tmp/repo/data/common.yaml', nil)
    end

    it 'never excludes findings with nil path' do
      scan = described_class.new(repo_dir: '/tmp/repo', incoming_dir: '/tmp/incoming')
      findings = [
        Driftless::Finding.new(key: 'x', path: nil, line: nil, message: 'a', meta: {}),
      ]
      expect(scan.send(:apply_exclude_paths, findings, ['**'], 'x')).to eq(findings)
    end

    it 'matches multiple patterns (any-match wins)' do
      scan = described_class.new(repo_dir: '/tmp/repo', incoming_dir: '/tmp/incoming')
      findings = [
        Driftless::Finding.new(key: 'x', path: '/tmp/repo/vendor/foo.pp', line: 1, message: 'v', meta: {}),
        Driftless::Finding.new(key: 'x', path: '/tmp/repo/modules/bar.pp', line: 1, message: 'm', meta: {}),
        Driftless::Finding.new(key: 'x', path: '/tmp/repo/site.pp',       line: 1, message: 's', meta: {}),
      ]
      result = scan.send(:apply_exclude_paths, findings, ['modules/**', 'vendor/**'], 'x')
      expect(result.map(&:path)).to eq(['/tmp/repo/site.pp'])
    end
  end
end
