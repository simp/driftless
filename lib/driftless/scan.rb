require 'pathname'

require 'driftless/corpus'
require 'driftless/logger'
require 'driftless/reported'
require 'driftless/detectors'
require 'driftless/inputs/hierarchy_loader'
require 'driftless/inputs/modulepath_loader'
require 'driftless/inputs/datadir_loader'
require 'driftless/inputs/report_loader'

module Driftless
  class Scan
    attr_reader :repo_dir, :incoming_dir, :only, :skip, :basemodulepath, :log

    def initialize(repo_dir:, incoming_dir:, only: nil, skip: nil, basemodulepath: nil, log: $stderr)
      @repo_dir       = repo_dir
      @incoming_dir   = incoming_dir
      @only           = only
      @skip           = skip
      @basemodulepath = basemodulepath
      @log            = log
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
        "Extracted #{puppet_classes.size} classes and #{code_lookup_calls.size} lookup calls from manifests"
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
      meta_findings.concat(rl_findings)
      Driftless.logger.info("Loaded PuppetDB reports from #{incoming_dir}")

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
        log:               log,
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

    # Times a block and emits a DEBUG line with elapsed ms. Level filtering
    # means the debug output only shows up when a caller has run `driftless -vv`.
    def phase(name)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
      Driftless.logger.debug("  [#{elapsed_ms}ms] #{name}")
      result
    end

    # Filters findings whose `path` matches any of the given glob patterns.
    # Patterns are matched against repo-relative paths. Findings without a
    # path (structural findings like `skipped:*`) are never excluded.
    # Each exclusion emits a DEBUG line naming the matching pattern.
    def apply_exclude_paths(findings, patterns, detector_key)
      return findings if patterns.empty?

      findings.reject do |f|
        next false unless f.path
        rel = relative_to_repo(f.path)
        # Deliberately NO FNM_PATHNAME — with it, `modules/**` would only match
        # a single segment under `modules/` (a Ruby-glob quirk). Users expect
        # `.gitignore`-style semantics where `modules/**` matches any depth.
        matched = patterns.find { |p| File.fnmatch(p, rel, File::FNM_EXTGLOB) }
        next false unless matched
        Driftless.logger.debug("  excluded by #{detector_key}.exclude_paths[#{matched}]: #{rel}")
        true
      end
    end

    def relative_to_repo(path)
      return path unless repo_dir
      Pathname.new(path).relative_path_from(Pathname.new(repo_dir)).to_s
    rescue ArgumentError
      # Path not under repo_dir (unusual — absolute path pointing elsewhere).
      # Fall back to the raw path; glob patterns can still target absolute paths.
      path
    end
  end
end
