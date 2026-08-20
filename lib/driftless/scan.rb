require 'pathname'

require 'driftless/corpus'
require 'driftless/logger'
require 'driftless/reported'
require 'driftless/config_keys'
require 'driftless/detectors'
require 'driftless/inputs/hierarchy_loader'
require 'driftless/inputs/modulepath_loader'
require 'driftless/inputs/datadir_loader'
require 'driftless/inputs/report_loader'
require 'driftless/inputs/summary_index'

module Driftless
  class Scan
    extend ConfigKeys::DSL

    config_key 'puppet.environments', type: :array, default: [],
               about: 'Puppet environments to scan (required)'
    config_key 'puppet.allow_missing_envs', type: :boolean, default: false,
               about: 'Warn instead of erroring when a listed environment has no reports'
    config_key 'reports.accept_duplicate_certnames', type: :boolean, default: false,
               about: 'Warn instead of erroring when one certname is reported by two collectors'

    attr_reader :repo_dir, :incoming_dir, :only, :skip, :basemodulepath,
                :environments, :allow_missing_envs, :summary_dir,
                :accept_partial_report_sessions, :accept_duplicate_certnames

    def initialize(repo_dir:, incoming_dir:, only: nil, skip: nil, basemodulepath: nil,
                   environments: nil, allow_missing_envs: false,
                   summary_dir: nil, accept_partial_report_sessions: nil,
                   accept_duplicate_certnames: false)
      @repo_dir                       = repo_dir
      @incoming_dir                   = incoming_dir
      @only                           = only
      @skip                           = skip
      @basemodulepath                 = basemodulepath
      @environments                   = environments
      @allow_missing_envs             = allow_missing_envs
      @summary_dir                    = summary_dir
      @accept_partial_report_sessions = accept_partial_report_sessions
      @accept_duplicate_certnames     = accept_duplicate_certnames
    end

    def run
      require 'driftless/inputs/manifest_parser'
      require 'driftless/inputs/epp_parser'
      require 'driftless/class_extractor'
      require 'driftless/lookup_calls'

      Driftless.logger.info("Scanning control repo: #{repo_dir}")
      meta_findings = []

      hiera_tiers, hl_findings = phase('hierarchy load') { Inputs::HierarchyLoader.load(repo_dir) }
      meta_findings.concat(hl_findings)
      Driftless.logger.info("Loaded #{hiera_tiers.size} hierarchy tiers")

      manifest_files, mpl_findings = phase('manifest discovery') { load_manifest_files }
      meta_findings.concat(mpl_findings)
      Driftless.logger.info("Discovered #{manifest_files.size} Puppet manifest files")

      puppet_classes    = {}
      code_lookup_calls = []
      data_lookup_calls = []

      phase('manifest parsing') do
        manifest_files.each do |path|
          program, errs = Inputs::ManifestParser.parse(path)
          meta_findings.concat(errs)
          next unless program
          ClassExtractor.extract(program: program, file: path).each do |cls|
            puppet_classes[cls.fqname] = cls
          end
          code_lookup_calls.concat(LookupCallExtractor.extract(program: program, file: path))
        end
      end
      Driftless.logger.info(
        "Extracted #{puppet_classes.size} classes and #{code_lookup_calls.size} lookup calls from manifests",
      )

      epp_paths = discover_epp_templates
      phase('EPP template scan') do
        epp_paths.each do |path|
          program, errs = Inputs::EppParser.parse(path)
          meta_findings.concat(errs)
          next unless program
          code_lookup_calls.concat(LookupCallExtractor.extract(program: program, file: path))
        end
      end
      Driftless.logger.info("Scanned #{epp_paths.size} EPP templates")

      data_files, dl_findings = phase('data file load') { Inputs::DatadirLoader.load(hiera_tiers) }
      meta_findings.concat(dl_findings)
      Driftless.logger.info("Loaded #{data_files.size} Hiera data files")

      reported, rl_findings = phase('report load') { Inputs::ReportLoader.load(incoming_dir) }
      phase('duplicate certname check') { check_duplicate_certnames!(reported) }
      meta_findings.concat(rl_findings)
      Driftless.logger.info("Loaded PuppetDB reports from #{incoming_dir}")

      phase('summary coverage check') { check_summary_coverage! }

      if environments&.any?
        reported = phase('environment filter') { apply_environment_filter(reported) }
        Driftless.logger.info("Filtered reports to environments: #{environments.join(', ')}")
      end

      phase('lookup extraction from Hiera data') do
        data_files.each do |df|
          next unless File.file?(df.path)
          data_lookup_calls.concat(LookupCallExtractor.extract_from_yaml_source(df.source, df.path))
        end
      end

      corpus = Corpus.new(
        repo_dir:          repo_dir,
        hiera_tiers:       hiera_tiers,
        puppet_classes:    puppet_classes,
        data_files:        data_files,
        reported:          reported,
        code_lookup_calls: code_lookup_calls,
        data_lookup_calls: data_lookup_calls,
      )

      detectors = selected_detectors
      Driftless.logger.info("Running #{detectors.size} detectors")
      detector_findings = detectors.flat_map do |klass|
        instance = klass.new(corpus)

        unless instance.option(:enabled)
          Driftless.logger.info("  #{klass.key} → disabled by config")
          next []
        end

        raw      = phase(klass.key) { instance.call }
        patterns = instance.option(:exclude_paths)
        filtered = apply_exclude_paths(raw, patterns, klass.key)

        excluded = raw.size - filtered.size
        summary  = "#{filtered.size} findings"
        summary += " (#{excluded} excluded by config)" if excluded > 0
        Driftless.logger.info("  #{klass.key} → #{summary}")
        filtered
      end

      all_findings = meta_findings + detector_findings
      relativize_finding_paths!(all_findings)
      Driftless.logger.info("Scan complete: #{all_findings.size} findings")
      all_findings
    end

    private

    def load_manifest_files
      if basemodulepath
        Inputs::ModulepathLoader.load(repo_dir, basemodulepath: basemodulepath)
      else
        Inputs::ModulepathLoader.load(repo_dir)
      end
    end

    def discover_epp_templates
      %w[site-modules modules].flat_map do |rel|
        dir = File.join(repo_dir, rel)
        next [] unless File.directory?(dir)
        Dir[File.join(dir, '*/templates/**/*.epp')]
      end
    end

    def selected_detectors
      d = Detectors.registry
      d = d.select { |k| only.include?(k.key) } if only && !only.empty?
      d = d.reject { |k| skip.include?(k.key) } if skip && !skip.empty?
      d
    end

    # Benchmarks a block's runtime and logs a DEBUG line with the elapsed ms
    def phase(name)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
      Driftless.logger.debug("  [#{elapsed_ms}ms] #{name}")
      result
    end

    # Filters findings whose `path` matches any of the given glob patterns.
    # Findings without a path (e.g.,`skipped:*`) are never excluded.
    def apply_exclude_paths(findings, patterns, detector_key)
      return findings if patterns.empty?

      findings.reject do |f|
        next false unless f.path
        rel = relative_to_repo(f.path)
        matched = patterns.find { |p| File.fnmatch(p, rel, File::FNM_EXTGLOB) }
        next false unless matched
        Driftless.logger.debug("  excluded by #{detector_key}.exclude_paths[#{matched}]: #{rel}")
        true
      end
    end

    # Rewrites each finding's path to repo-relative form is under repo_dir
    # Paths outside the repo stay absolute to stay sensible
    def relativize_finding_paths!(findings)
      return findings unless repo_dir
      prefix = repo_dir.end_with?('/') ? repo_dir : "#{repo_dir}/"
      findings.each do |f|
        next unless f.path
        f.path = f.path[prefix.length..] if f.path.start_with?(prefix)
      end
      findings
    end

    def relative_to_repo(path)
      return path unless repo_dir
      Pathname.new(path).relative_path_from(Pathname.new(repo_dir)).to_s
    rescue ArgumentError
      # Path not under repo_dir (unusual — absolute path pointing elsewhere).
      # Fall back to the raw path; glob patterns can still target absolute paths.
      path
    end

    # Compares each collector's latest session summary against the expected
    # report set (union of enabled detectors' `requires_reports`). Gaps mean
    # scan would run against a tree cleanup would quarantine.
    #
    # - No summary_dir wired / missing dir / no summaries → no-op (fresh state
    #   or all archived is vacuously OK).
    # - --accept-partial-report-sessions bare → skip entirely.
    # - --accept-partial-report-sessions=A,B,C → warn on gap, expected = list.
    # - No flag (strict) → raise ScanError on gap.
    def check_summary_coverage!
      return unless @summary_dir

      expected =
        case @accept_partial_report_sessions
        when :bare  then return
        when Array  then @accept_partial_report_sessions.map(&:to_s).uniq.sort
        else             Detectors.expected_reports
        end
      return if expected.empty?

      latest = Inputs::SummaryIndex.latest_per_collector(@summary_dir)
      return if latest.empty?

      strict = @accept_partial_report_sessions.nil?
      gaps = latest.each_with_object({}) do |(collector, entry), acc|
        missing = expected.reject do |r|
          e = entry.reports_declared[r]
          e.is_a?(Hash) && e['status'] == 'ok'
        end
        acc[collector] = missing unless missing.empty?
      end
      return if gaps.empty?

      per_collector = gaps.map { |c, m| "#{c} missing #{m.join(',')}" }.join('; ')
      if strict
        raise ScanError,
              "collector coverage gap: #{per_collector} " \
              "(run `driftless import cleanup` to garden #{@incoming_dir}, " \
              'or pass --accept-partial-report-sessions)'
      else
        gaps.each do |collector, missing|
          Driftless.logger.warn(
            "scan: collector #{collector} missing expected reports #{missing.inspect} " \
            '(accepting partial session per --accept-partial-report-sessions)',
          )
        end
      end
    end

    def check_duplicate_certnames!(reported)
      dups = reported.duplicate_certnames
      return if dups.nil? || dups.empty?

      described = dups.map { |certname, collectors| "#{certname} (#{collectors.join(', ')})" }

      unless @accept_duplicate_certnames
        raise ScanError,
              "certname reported by more than one collector: #{described.join('; ')} " \
              '— an agent belongs to one PuppetDB ecosystem, so the report set is ' \
              'inconsistent and findings drawn from it cannot be trusted. Investigate ' \
              'the collectors, or pass --accept-duplicate-certnames to scan anyway.'
      end

      dups.each do |certname, collectors|
        Driftless.logger.warn(
          "certname #{certname.inspect} reported by #{collectors.length} collectors " \
          "(#{collectors.join(', ')}); keeping the newest record " \
          '(accepted per accept_duplicate_certnames)',
        )
      end
    end

    def apply_environment_filter(reported)
      require 'set'

      # Precedes the env-mismatch loop so an empty inventory reads as
      # "no reports" rather than as a puppet.environments misconfiguration.
      if Inputs::ReportLoader::QUERIES.all? { |q| reported.missing?(q) }
        msg = "no PuppetDB reports loaded from #{incoming_dir} " \
              '(expected <query>/<collector>--<timestamp>.{json,ndjson} ' \
              "files under at least one of: #{Inputs::ReportLoader::QUERIES.join(', ')})"
        raise ScanError, msg unless allow_missing_envs
        Driftless.logger.warn(msg)
        return reported

      end

      env_set   = Set.new(environments)
      seen_envs = Set.new

      filtered_data = {}
      Inputs::ReportLoader::QUERIES.each do |query|
        next if reported.missing?(query)

        kept = reported.report(query).select do |node|
          env = node.environment
          if env.nil?
            true
          elsif env_set.include?(env)
            seen_envs << env
            true
          else
            Driftless.logger.info("  node #{node.certname.inspect} excluded (environment #{env.inspect} not in puppet.environments)")
            false
          end
        end
        filtered_data[query] = kept
      end

      (env_set - seen_envs).each do |env|
        msg = "environment #{env.inspect} listed in puppet.environments but has no reports in #{incoming_dir}"
        raise ScanError, msg unless allow_missing_envs
        Driftless.logger.warn(msg)
      end

      Reported.new(data: filtered_data)
    end
  end

  class ScanError < StandardError; end
end
