require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/detectors'
require 'driftless/inputs/hierarchy_loader'
require 'driftless/inputs/modulepath_loader'
require 'driftless/inputs/datadir_loader'

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

      meta_findings = []

      hiera_tiers, hl_findings = Inputs::HierarchyLoader.load(repo_dir)
      meta_findings.concat(hl_findings)

      manifest_files, mpl_findings = load_manifest_files
      meta_findings.concat(mpl_findings)

      puppet_classes = {}
      lookup_calls   = []

      manifest_files.each do |path|
        program, errs = Inputs::ManifestParser.parse(path)
        meta_findings.concat(errs)
        next unless program
        ClassExtractor.extract(program: program, file: path).each do |cls|
          puppet_classes[cls.fqname] = cls
        end
        lookup_calls.concat(LookupCallExtractor.extract(program: program, file: path))
      end

      discover_epp_templates.each do |path|
        program, errs = Inputs::EppParser.parse(path)
        meta_findings.concat(errs)
        next unless program
        lookup_calls.concat(LookupCallExtractor.extract(program: program, file: path))
      end

      data_files, dl_findings = Inputs::DatadirLoader.load(hiera_tiers)
      meta_findings.concat(dl_findings)

      data_files.each do |df|
        next unless File.file?(df.path)
        lookup_calls.concat(LookupCallExtractor.extract_from_yaml_source(File.read(df.path), df.path))
      end

      corpus = Corpus.new(
        repo:           nil,
        hiera_tiers:    hiera_tiers,
        puppet_classes: puppet_classes,
        data_files:     data_files,
        reported:       Reported.new(data: {}),
        lookup_calls:   lookup_calls,
        log:            log,
      )

      meta_findings + selected_detectors.flat_map { |klass| klass.new(corpus).call }
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
  end
end
