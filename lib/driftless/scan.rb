require 'driftless/corpus'
require 'driftless/reported'
require 'driftless/detectors'

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
      corpus = build_corpus
      selected_detectors.flat_map { |klass| klass.new(corpus).call }
    end

    private

    def build_corpus
      Corpus.new(
        repo: nil,
        hiera_tiers: [],
        puppet_classes: {},
        data_files: [],
        reported: Reported.new(data: {}),
        lookup_calls: [],
        log: log,
      )
    end

    def selected_detectors
      d = Detectors.registry
      d = d.select { |k| only.include?(k.key) } if only && !only.empty?
      d = d.reject { |k| skip.include?(k.key) } if skip && !skip.empty?
      d
    end
  end
end
