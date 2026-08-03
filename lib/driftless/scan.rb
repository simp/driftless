require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/detectors'
require 'driftless/inputs/hierarchy_loader'

module Driftless
  class Scan
    attr_reader :repo_dir, :incoming_dir, :only, :skip, :log

    def initialize(repo_dir:, incoming_dir:, only: nil, skip: nil, log: $stderr)
      @repo_dir     = repo_dir
      @incoming_dir = incoming_dir
      @only         = only
      @skip         = skip
      @log          = log
    end

    def run
      meta_findings = []

      hiera_tiers, hl_findings = Inputs::HierarchyLoader.load(repo_dir)
      meta_findings.concat(hl_findings)

      corpus = Corpus.new(
        repo:           nil,
        hiera_tiers:    hiera_tiers,
        puppet_classes: {},
        data_files:     [],
        reported:       Reported.new(data: {}),
        lookup_calls:   [],
        log:            log,
      )

      meta_findings + selected_detectors.flat_map { |klass| klass.new(corpus).call }
    end

    private

    def selected_detectors
      d = Detectors.registry
      d = d.select { |k| only.include?(k.key) } if only && !only.empty?
      d = d.reject { |k| skip.include?(k.key) } if skip && !skip.empty?
      d
    end
  end
end
