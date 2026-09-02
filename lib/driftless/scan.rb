require 'pathname'

require 'driftless/corpus'
require 'driftless/logger'
require 'driftless/reported'
require 'driftless/reported_checks'
require 'driftless/scan_error'
require 'driftless/detectors'
require 'driftless/inputs/hierarchy_loader'
require 'driftless/inputs/modulepath_loader'
require 'driftless/inputs/puppetfile'
require 'driftless/inputs/datadir_loader'
require 'driftless/inputs/report_loader'

module Driftless
  class Scan
    include ReportedChecks

    attr_reader :repo_dir, :only, :skip, :basemodulepath

    # @return [Corpus, nil] the read model the detectors ran against; nil until
    #   {#run} builds it. Findings alone cannot answer node counts or
    #   utilization, so consumers of a finished scan read them from here.
    attr_reader :corpus

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
      halt_without_hiera_yaml!(hl_findings)
      Driftless.logger.info("Loaded #{hiera_tiers.size} hierarchy tiers")

      manifest_files, mpl_findings = phase('manifest discovery') { load_manifest_files }
      meta_findings.concat(mpl_findings)
      Driftless.logger.info("Discovered #{manifest_files.size} Puppet manifest files")

      puppetfile = phase('Puppetfile load') { Inputs::Puppetfile.load(repo_dir) }
      warn("Puppetfile not evaluated: #{puppetfile.error}") if puppetfile.error
      Driftless.logger.info("Read #{puppetfile.modules.size} module declarations from the Puppetfile") if puppetfile.exists?

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
          data_lookup_calls.concat(LookupCallExtractor.extract_from_yaml_values(df.value_lines, df.path))
        end
      end

      @corpus = corpus = Corpus.new(
        repo_dir:          repo_dir,
        hiera_tiers:       hiera_tiers,
        puppet_classes:    puppet_classes,
        data_files:        data_files,
        reported:          reported,
        code_lookup_calls: code_lookup_calls,
        data_lookup_calls: data_lookup_calls,
        puppetfile:        puppetfile,
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

      all_findings = apply_registration_config(meta_findings) + detector_findings
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

    # Without hiera.yaml there is no hierarchy to lint: every detector runs
    # against zero tiers, so the scan reports nothing and reads as a clean
    # repo. Stop instead. Disabling the key opts out of stopping, since the
    # finding it would have been reported as is dropped either way.
    def halt_without_hiera_yaml!(findings)
      registration = Detectors::HierarchyHieraYamlMissing
      finding      = findings.find { |f| f.key == registration.key }
      return if finding.nil? || !registration.new.option(:enabled)

      raise ScanError, finding.message
    end

    # Applies :enabled and :exclude_paths to the findings raised under each
    # registration's key while the corpus was built. Two kinds pass through
    # untouched: a key carrying no registration, and a detector's key, whose
    # findings the detector loop has already filtered.
    def apply_registration_config(findings)
      findings.group_by(&:key).flat_map do |key, group|
        registration = Detectors.find(key)
        next group if registration.nil? || registration.callable?

        instance = registration.new
        unless instance.option(:enabled)
          Driftless.logger.info("  #{key} → disabled by config")
          next []
        end
        apply_exclude_paths(group, instance.option(:exclude_paths), key)
      end
    end

    def selected_detectors
      d = Detectors.registry.select(&:callable?)
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

    def expected_reports
      Detectors.expected_reports
    end
  end
end
