require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'fileutils'

require 'driftless/scan'
require 'driftless/inputs/report_loader'

RSpec.describe Driftless::Scan do
  # Save/restore Driftless.config around every example — Scan#run reads it
  # per-detector via option() calls.
  around(:each) do |ex|
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

  # It's really annoying when PuppetDB reports stderr warnings show up in the
  # middle of RSPec test results
  def silence_driftless_logger
    fake_logger = instance_double(Logger, debug: true, info: true, warn: true, error: true, fatal: true)
    allow(Driftless).to receive(:logger).and_return(fake_logger)
  end

  # Spot-check: confirm scan.rb actually calls Driftless.logger during a run.
  # A single canary test proves the wire between the log-emitter and the logger
  # is intact end-to-end; per-line coverage is deferred until it earns its keep.
  describe 'log narration' do
    around(:each) do |example|
      captured        = StringIO.new
      original_logger = Driftless.logger
      Driftless.logger = Logger.new(captured, level: Logger::INFO)
      Driftless.logger.formatter = Driftless::Logging.formatter
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

        expect(@captured.string).to include('info: Scanning control repo: ')
        expect(@captured.string).to match(/info: Loaded \d+ hierarchy tiers/)
        expect(@captured.string).to match(/info: Scan complete: \d+ findings/)
      end
    end
  end

  describe 'detector :enabled config' do
    around(:each) do |ex|
      captured        = StringIO.new
      original_logger = Driftless.logger
      Driftless.logger = Logger.new(captured, level: Logger::INFO)
      Driftless.logger.formatter = Driftless::Logging.formatter
      @captured = captured
      ex.run
    ensure
      Driftless.logger = original_logger
    end

    it 'skips detectors whose option(:enabled) is false' do
      Dir.mktmpdir do |dir|
        minimal_repo(dir)
        set_config('detectors' => { 'hierarchy:files-missed-by-reported-fact-values' => { 'enabled' => false } })

        findings = described_class.new(repo_dir: dir, incoming_dir: File.join(dir, 'incoming')).run

        # No hierarchy:files-missed-by-reported-fact-values findings — the detector was skipped.
        expect(findings.map(&:key)).not_to include('hierarchy:files-missed-by-reported-fact-values')
        expect(findings.map(&:key)).not_to include('skipped:hierarchy:files-missed-by-reported-fact-values')

        # And the log narrates the skip.
        expect(@captured.string).to include('hierarchy:files-missed-by-reported-fact-values → disabled by config')
      end
    end

    # Loader Registrations sit in the same registry and answer callable? false
    # Only the detectors are run.
    it 'does not run a registration that is not callable' do
      Class.new(Driftless::Detectors::Registration) { key 'test:not-callable' }

      Dir.mktmpdir do |dir|
        minimal_repo(dir)
        expect { described_class.new(repo_dir: dir, incoming_dir: File.join(dir, 'incoming')).run }
          .not_to raise_error
        expect(@captured.string).not_to include('test:not-callable')
      end
    end
  end

  # A repo with no hiera.yaml has no hierarchy to lint, so every detector would
  # run against zero tiers and the scan would report nothing.
  describe 'a control repo with no hiera.yaml' do
    def repo_without_hiera_yaml
      dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(dir, 'incoming'))
      File.write(File.join(dir, 'environment.conf'), "modulepath = modules\n")
      dir
    end

    before(:each) { silence_driftless_logger }

    it 'stops the scan instead of reporting nothing' do
      dir = repo_without_hiera_yaml
      expect { described_class.new(repo_dir: dir, incoming_dir: File.join(dir, 'incoming')).run }
        .to raise_error(Driftless::ScanError, /no hiera\.yaml at/)
    ensure
      FileUtils.remove_entry(dir)
    end

    it 'does not stop when the key is disabled' do
      dir = repo_without_hiera_yaml
      set_config('detectors' => { 'hierarchy:hiera-yaml-missing' => { 'enabled' => false } })
      findings = described_class.new(repo_dir: dir, incoming_dir: File.join(dir, 'incoming')).run
      expect(findings.map(&:key)).not_to include('hierarchy:hiera-yaml-missing')
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  # Findings raised while the corpus is built are registered under their own
  # keys, so a config file reaches them the same way it reaches a detector's.
  describe 'config applied to registrations raised by the inputs' do
    def unsupported_version_repo(dir)
      minimal_repo(dir)
      File.write(File.join(dir, 'hiera.yaml'), "---\nversion: 4\n")
    end

    def scan(dir)
      described_class.new(repo_dir: dir, incoming_dir: File.join(dir, 'incoming')).run
    end

    before(:each) { silence_driftless_logger }

    it 'raises the finding when nothing disables it' do
      Dir.mktmpdir do |dir|
        unsupported_version_repo(dir)
        expect(scan(dir).map(&:key)).to include('hierarchy:unsupported-version')
      end
    end

    it 'drops the finding when its key is disabled' do
      Dir.mktmpdir do |dir|
        unsupported_version_repo(dir)
        set_config('detectors' => { 'hierarchy:unsupported-version' => { 'enabled' => false } })
        expect(scan(dir).map(&:key)).not_to include('hierarchy:unsupported-version')
      end
    end

    it 'drops the finding when its path is excluded' do
      Dir.mktmpdir do |dir|
        unsupported_version_repo(dir)
        set_config('detectors' => {
          'hierarchy:unsupported-version' => { 'exclude_paths' => ['hiera.yaml'] },
        })
        expect(scan(dir).map(&:key)).not_to include('hierarchy:unsupported-version')
      end
    end

    # Both pass-through branches, reached directly: nothing #run collects today
    # carries a key of either shape.
    describe 'keys the filter does not own' do
      let(:scanner) { described_class.new(repo_dir: '/nonexistent', incoming_dir: '/nonexistent') }

      def finding(key)
        Driftless::Finding.new(key: key, message: 'x', path: 'a.yaml')
      end

      it 'passes through a finding whose key carries no registration' do
        f = finding('not:registered')
        expect(scanner.send(:apply_registration_config, [f])).to eq([f])
      end

      it 'passes through a finding under a detector key' do
        f = finding('data:legacy-facts')
        expect(scanner.send(:apply_registration_config, [f])).to eq([f])
      end
    end

    it 'grades the finding from its registration rather than the emit site' do
      Dir.mktmpdir do |dir|
        minimal_repo(dir)
        File.write(File.join(dir, 'hiera.yaml'), <<~YAML)
          ---
          version: 5
          hierarchy:
            - name: 'No path'
        YAML
        f = scan(dir).find { |x| x.key == 'hierarchy:tier-missing-path' }
        expect(f.severity).to eq(Driftless::Detectors::HierarchyTierMissingPath.severity)
        expect(f.severity).to eq(:note)
      end
    end
  end

  describe '#apply_environment_filter' do
    def make_node(certname:, environment:)
      Driftless::Node.new(certname: certname, environment: environment, facts: {}, trusted: {})
    end

    def make_reported(nodes)
      Driftless::Reported.new(data: { 'all-active-nodes' => nodes })
    end

    def filter_scan(environments:, allow_missing_envs: false)
      described_class.new(
        repo_dir:           '/tmp',
        incoming_dir:       '/tmp/incoming',
        environments:       environments,
        allow_missing_envs: allow_missing_envs,
      )
    end

    it 'passes nodes whose environment is in the list' do
      scan     = filter_scan(environments: ['production'])
      reported = make_reported([make_node(certname: 'web1', environment: 'production')])
      result   = scan.send(:apply_environment_filter, reported)
      expect(result.report('all-active-nodes').map(&:certname)).to eq(['web1'])
    end

    # Every report is a list of Nodes, so the same filter drops a node's class
    # list when it drops the node.
    it 'filters the classes report alongside the node reports' do
      scan     = filter_scan(environments: ['production'], allow_missing_envs: true)
      reported = Driftless::Reported.new(data: {
        'all-active-nodes' => [
          make_node(certname: 'web1', environment: 'production'),
          make_node(certname: 'dev1', environment: 'dev'),
        ],
        'classes-for-all-active-nodes' => [
          Driftless::Node.new(certname: 'web1', classes: ['Role::Web'], environment: 'production'),
          Driftless::Node.new(certname: 'dev1', classes: ['Role::Dev'], environment: 'dev'),
        ],
      })

      result = scan.send(:apply_environment_filter, reported)
      expect(result.report('all-active-nodes').map(&:certname)).to eq(['web1'])
      expect(result.report('classes-for-all-active-nodes').map(&:certname)).to eq(['web1'])
    end

    it 'excludes nodes whose environment is not listed' do
      scan     = filter_scan(environments: ['production'], allow_missing_envs: true)
      reported = make_reported([
        make_node(certname: 'web1', environment: 'production'),
        make_node(certname: 'dev1', environment: 'dev'),
      ])
      result = scan.send(:apply_environment_filter, reported)
      expect(result.report('all-active-nodes').map(&:certname)).to eq(['web1'])
    end

    it 'passes nodes with nil environment through unconditionally' do
      silence_driftless_logger
      scan     = filter_scan(environments: ['production'], allow_missing_envs: true)
      reported = make_reported([make_node(certname: 'legacy', environment: nil)])
      result   = scan.send(:apply_environment_filter, reported)
      expect(result.report('all-active-nodes').map(&:certname)).to eq(['legacy'])
    end

    it 'raises ScanError when a listed env has no reports and allow_missing_envs is false' do
      scan     = filter_scan(environments: %w[production staging])
      reported = make_reported([make_node(certname: 'web1', environment: 'production')])
      expect { scan.send(:apply_environment_filter, reported) }
        .to raise_error(Driftless::ScanError, /staging/)
    end

    it 'warns instead of raising when allow_missing_envs is true' do
      silence_driftless_logger
      scan     = filter_scan(environments: %w[production staging], allow_missing_envs: true)
      reported = make_reported([make_node(certname: 'web1', environment: 'production')])
      expect { scan.send(:apply_environment_filter, reported) }.not_to raise_error
    end

    it 'records the warning in #warnings for end-of-run replay' do
      silence_driftless_logger
      scan     = filter_scan(environments: %w[production staging], allow_missing_envs: true)
      reported = make_reported([make_node(certname: 'web1', environment: 'production')])
      scan.send(:apply_environment_filter, reported)
      expect(scan.warnings).to contain_exactly(a_string_including('staging'))
    end

    it 'keeps MissingReport queries absent from the filtered result' do
      silence_driftless_logger
      scan     = filter_scan(environments: ['production'], allow_missing_envs: true)
      reported = Driftless::Reported.new(data: {})
      result   = scan.send(:apply_environment_filter, reported)
      expect(result.missing?('all-active-nodes')).to be true
    end

    context 'when every report query is MissingReport (empty inventory)' do
      let(:empty_reported) { Driftless::Reported.new(data: {}) }

      it 'raises ScanError with a message that names the incoming_dir, not puppet.environments' do
        scan = filter_scan(environments: %w[production staging])
        expect { scan.send(:apply_environment_filter, empty_reported) }
          .to raise_error(Driftless::ScanError) { |e|
            expect(e.message).to include('no PuppetDB reports loaded from /tmp/incoming')
            expect(e.message).not_to include('puppet.environments')
          }
      end

      it 'warns and returns the (still-empty) reported when allow_missing_envs is true' do
        silence_driftless_logger
        scan   = filter_scan(environments: ['production'], allow_missing_envs: true)
        result = scan.send(:apply_environment_filter, empty_reported)
        expect(result.missing?('all-active-nodes')).to be true
        expect(result.missing?('factsets-for-all-active-nodes')).to be true
      end

      it 'names the expected file-layout shape in its message' do
        scan = filter_scan(environments: ['production'])
        expect { scan.send(:apply_environment_filter, empty_reported) }
          .to raise_error(Driftless::ScanError, /collector.*timestamp.*ndjson/)
      end
    end
  end

  describe '#relativize_finding_paths!' do
    let(:scan) { described_class.new(repo_dir: '/tmp/repo', incoming_dir: '/tmp/incoming') }

    def finding(path)
      Driftless::Finding.new(key: 'x', path: path, line: nil, message: 'm', meta: {})
    end

    it 'rewrites paths under repo_dir to repo-relative form' do
      f = finding('/tmp/repo/data/common.yaml')
      scan.send(:relativize_finding_paths!, [f])
      expect(f.path).to eq('data/common.yaml')
    end

    it 'leaves paths outside repo_dir absolute' do
      f = finding('/etc/puppetlabs/code/modules/stdlib/manifests/init.pp')
      scan.send(:relativize_finding_paths!, [f])
      expect(f.path).to eq('/etc/puppetlabs/code/modules/stdlib/manifests/init.pp')
    end

    it 'does not strip when a path merely shares a prefix with repo_dir but is not under it' do
      # /tmp/repo-other/... starts with "/tmp/repo" but is not under "/tmp/repo/".
      # The trailing-slash guard in the helper is what prevents a wrong strip here.
      f = finding('/tmp/repo-other/data/common.yaml')
      scan.send(:relativize_finding_paths!, [f])
      expect(f.path).to eq('/tmp/repo-other/data/common.yaml')
    end

    it 'leaves nil-path findings alone' do
      f = finding(nil)
      scan.send(:relativize_finding_paths!, [f])
      expect(f.path).to be_nil
    end

    it 'no-ops when repo_dir is nil' do
      s = described_class.new(repo_dir: nil, incoming_dir: '/tmp/incoming')
      f = finding('/tmp/repo/data/common.yaml')
      s.send(:relativize_finding_paths!, [f])
      expect(f.path).to eq('/tmp/repo/data/common.yaml')
    end

    it 'end-to-end: Scan#run emits repo-relative paths' do
      silence_driftless_logger
      Dir.mktmpdir do |dir|
        minimal_repo(dir)
        # Plant an orphan data file so hierarchy:unreachable-data-files fires;
        # it's inventory-independent and reliably yields a path-carrying finding.
        File.write(File.join(dir, 'data', 'orphan.yaml'), "---\n{}\n")
        set_config('puppet' => { 'environments' => ['production'] })
        findings = described_class.new(
          repo_dir:     dir,
          incoming_dir: File.join(dir, 'incoming'),
          environments: ['production'],
          allow_missing_envs: true,
        ).run

        paths = findings.map(&:path).compact
        expect(paths).to include('data/orphan.yaml')
        expect(paths.none? { |p| p.start_with?('/') }).to be(true), "expected all paths relative, got #{paths.inspect}"
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
        Driftless::Finding.new(key: 'x', path: '/tmp/repo/site.pp', line: 1, message: 's', meta: {}),
      ]
      result = scan.send(:apply_exclude_paths, findings, ['modules/**', 'vendor/**'], 'x')
      expect(result.map(&:path)).to eq(['/tmp/repo/site.pp'])
    end
  end

  describe '#check_duplicate_certnames!' do
    def scan_with(accept: false)
      described_class.new(repo_dir: '/tmp/repo', incoming_dir: '/tmp/incoming',
                          accept_duplicate_certnames: accept)
    end

    def reported_with(duplicates)
      Driftless::Reported.new(data: {}, duplicate_certnames: duplicates)
    end

    it 'no-ops when no certname is claimed twice' do
      expect { scan_with.send(:check_duplicate_certnames!, reported_with({})) }.not_to raise_error
    end

    it 'raises ScanError naming the certname and both collectors' do
      expect { scan_with.send(:check_duplicate_certnames!, reported_with('a.example.com' => %w[east west])) }
        .to raise_error(Driftless::ScanError, /a\.example\.com \(east, west\)/)
    end

    it 'points at the override rather than just failing' do
      expect { scan_with.send(:check_duplicate_certnames!, reported_with('a' => %w[east west])) }
        .to raise_error(Driftless::ScanError, /--accept-duplicate-certnames/)
    end

    it 'names every affected certname, not just the first' do
      dups = { 'a' => %w[east west], 'b' => %w[east west] }
      expect { scan_with.send(:check_duplicate_certnames!, reported_with(dups)) }
        .to raise_error(Driftless::ScanError, /a \(east, west\).*b \(east, west\)/)
    end

    context 'with accept_duplicate_certnames' do
      it 'warns once per certname instead of raising' do
        expect(Driftless.logger).to receive(:warn).with(/a\.example\.com.*east, west/).once
        expect { scan_with(accept: true).send(:check_duplicate_certnames!, reported_with('a.example.com' => %w[east west])) }
          .not_to raise_error
      end

      it 'still warns for every affected certname' do
        expect(Driftless.logger).to receive(:warn).twice
        scan_with(accept: true).send(:check_duplicate_certnames!, reported_with('a' => %w[e w], 'b' => %w[e w]))
      end
    end
  end

  describe '#check_summary_coverage!' do
    def scan_with(summary_dir:, override: nil, incoming: '/tmp/incoming')
      described_class.new(
        repo_dir:                       '/tmp/repo',
        incoming_dir:                   incoming,
        summary_dir:                    summary_dir,
        accept_partial_report_sessions: override,
      )
    end

    def write_summary(dir, collector, session_id, reports)
      FileUtils.mkdir_p(dir)
      File.write(
        File.join(dir, "#{collector}--#{session_id}.json"),
        JSON.generate('collector' => collector, 'session_id' => session_id, 'reports' => reports),
      )
    end

    # Stubs Detectors.expected_reports so the tests don't drift when
    # detectors are added/removed.
    before(:each) do
      allow(Driftless::Detectors).to receive(:expected_reports)
        .and_return(%w[all-active-nodes factsets-for-all-active-nodes])
    end

    it 'no-ops when summary_dir is nil' do
      expect { scan_with(summary_dir: nil).send(:check_summary_coverage!) }.not_to raise_error
    end

    it 'no-ops when summary_dir does not exist' do
      expect { scan_with(summary_dir: '/nonexistent/here').send(:check_summary_coverage!) }.not_to raise_error
    end

    it 'no-ops when summary_dir is empty' do
      Dir.mktmpdir do |dir|
        expect { scan_with(summary_dir: dir).send(:check_summary_coverage!) }.not_to raise_error
      end
    end

    it 'passes when every expected report is status:ok in the latest summary' do
      Dir.mktmpdir do |dir|
        write_summary(dir, 'c1', 's1', {
          'all-active-nodes'              => { 'status' => 'ok' },
          'factsets-for-all-active-nodes' => { 'status' => 'ok' },
        })
        expect { scan_with(summary_dir: dir).send(:check_summary_coverage!) }.not_to raise_error
      end
    end

    it 'raises ScanError when the latest summary is missing an expected report (strict)' do
      Dir.mktmpdir do |dir|
        write_summary(dir, 'c1', 's1', {
          'all-active-nodes' => { 'status' => 'ok' },
        })
        expect { scan_with(summary_dir: dir).send(:check_summary_coverage!) }
          .to raise_error(Driftless::ScanError, /c1 missing factsets-for-all-active-nodes/)
      end
    end

    it 'raises ScanError when an expected report has non-ok status (strict)' do
      Dir.mktmpdir do |dir|
        write_summary(dir, 'c1', 's1', {
          'all-active-nodes'              => { 'status' => 'ok' },
          'factsets-for-all-active-nodes' => { 'status' => 'failed' },
        })
        expect { scan_with(summary_dir: dir).send(:check_summary_coverage!) }
          .to raise_error(Driftless::ScanError, /factsets-for-all-active-nodes/)
      end
    end

    it 'includes the cleanup remediation hint in the error message' do
      Dir.mktmpdir do |dir|
        write_summary(dir, 'c1', 's1', { 'all-active-nodes' => { 'status' => 'ok' } })
        expect { scan_with(summary_dir: dir, incoming: '/tmp/xyz').send(:check_summary_coverage!) }
          .to raise_error(Driftless::ScanError) { |e|
            expect(e.message).to include('driftless import cleanup')
            expect(e.message).to include('/tmp/xyz')
            expect(e.message).to include('--accept-partial-report-sessions')
          }
      end
    end

    it 'checks the LATEST session per collector, not older ones' do
      Dir.mktmpdir do |dir|
        # Older session was partial…
        write_summary(dir, 'c1', '2026-01-01T00-00-00Z', { 'all-active-nodes' => { 'status' => 'ok' } })
        # …newer session covers everything → passes.
        write_summary(dir, 'c1', '2026-06-01T00-00-00Z', {
          'all-active-nodes'              => { 'status' => 'ok' },
          'factsets-for-all-active-nodes' => { 'status' => 'ok' },
        })
        expect { scan_with(summary_dir: dir).send(:check_summary_coverage!) }.not_to raise_error
      end
    end

    it 'reports gaps for each affected collector in strict mode' do
      Dir.mktmpdir do |dir|
        write_summary(dir, 'alpha', 's1', { 'all-active-nodes' => { 'status' => 'ok' } })
        write_summary(dir, 'beta',  's1', { 'all-active-nodes' => { 'status' => 'ok' } })
        expect { scan_with(summary_dir: dir).send(:check_summary_coverage!) }
          .to raise_error(Driftless::ScanError) { |e|
            expect(e.message).to include('alpha missing')
            expect(e.message).to include('beta missing')
          }
      end
    end

    context 'with --accept-partial-report-sessions bare' do
      it 'skips the check entirely — no error even when reports are missing' do
        Dir.mktmpdir do |dir|
          write_summary(dir, 'c1', 's1', {}) # nothing declared
          expect { scan_with(summary_dir: dir, override: :bare).send(:check_summary_coverage!) }.not_to raise_error
        end
      end
    end

    context 'with --accept-partial-report-sessions=A,B (Array)' do
      it 'checks against the given list, not the derived expected set' do
        Dir.mktmpdir do |dir|
          # Derived set (mocked): all-active-nodes + factsets-*. Override list demands only 'all-active-nodes'.
          write_summary(dir, 'c1', 's1', { 'all-active-nodes' => { 'status' => 'ok' } })
          expect(Driftless.logger).not_to receive(:warn)
          expect {
            scan_with(summary_dir: dir, override: ['all-active-nodes']).send(:check_summary_coverage!)
          }.not_to raise_error
        end
      end

      it 'warns instead of raising when the given list is not covered' do
        Dir.mktmpdir do |dir|
          write_summary(dir, 'c1', 's1', { 'all-active-nodes' => { 'status' => 'ok' } })
          expect(Driftless.logger).to receive(:warn).with(/c1 missing.*wanted-but-absent/)
          expect {
            scan_with(summary_dir: dir, override: ['wanted-but-absent']).send(:check_summary_coverage!)
          }.not_to raise_error
        end
      end
    end
  end
end
