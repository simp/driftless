require 'time'

require 'driftless/repo_data'
require 'driftless/version'
require 'driftless/json_document'
require 'driftless/outputs/json_writer'

module Driftless
  # The document `scan --data-file` writes: everything a finished scan knows
  # that the terminal writers cannot carry — which sessions and nodes it
  # read, the overrides it ran under, the repo revision, its warnings —
  # beside the findings. `site` builds from it.
  module ScanData
    DOCUMENT       = 'scan'.freeze
    SCHEMA_VERSION = 1

    # Where `scan --data-file` writes and `site` reads when neither is told
    # otherwise; relative to the working directory.
    DEFAULT_PATH = 'public/scan.json'.freeze

    # The report whose rows are counted for `nodes`.
    NODES_REPORT = 'all-active-nodes'.freeze

    # Key under which nodes with no collector or environment are tallied.
    UNKNOWN = '(unknown)'.freeze

    module_function

    # @param findings [Array<Finding>] what {Scan#run} returned
    # @param corpus [Corpus] {Scan#corpus} after the run
    # @param warnings [Array<String>] {Scan#warnings}
    # @param environments [Array<String>, nil] the environments scanned
    # @param overrides [Hash] see {overrides_from}
    # @param now [Time] stamp for `generated_at`; injectable for specs
    # @return [Hash] string-keyed, ready for JSON.generate
    def assemble(findings:, corpus:, warnings:, environments:, overrides:, now: Time.now)
      {
        'document'          => DOCUMENT,
        'schema_version'    => SCHEMA_VERSION,
        'generated_at'      => now.utc.iso8601,
        'driftless_version' => VERSION,
        'repo'              => RepoData.describe(corpus),
        'environments'      => Array(environments),
        'overrides'         => overrides,
        'sessions'          => sessions(corpus.reported),
        # Fleet description; the report document carries the same tally,
        # and `site` prefers its copy.
        'nodes'             => nodes(corpus.reported),
        'findings'          => finding_rows(findings),
        'warnings'          => warnings.dup,
      }
    end

    # The acceptance rules a scan was told to relax, so a reader of the
    # document knows its sessions may be spliced or its inventory partial.
    def overrides_from(scanner)
      partial = scanner.accept_partial_report_sessions
      {
        'accept_partial_report_sessions' => (partial == :bare) ? 'bare' : partial,
        'accept_duplicate_certnames'     => scanner.accept_duplicate_certnames ? true : false,
        'proceed_with_subset_of_configured_envs' => scanner.proceed_with_subset_of_configured_envs ? true : false,
      }
    end

    def write(data, path)
      JsonDocument.write(data, path)
    end

    # @raise [JsonDocument::Error]
    def read(path)
      JsonDocument.read(path, document: DOCUMENT, schema_version: SCHEMA_VERSION)
    end

    # Same order as the JSON writer, so the document and `-f json` agree.
    def finding_rows(findings)
      findings
        .sort_by { |f| [f.key, f.path.to_s, f.line || 0] }
        .map { |f| Outputs::JsonWriter.finding_to_h(f).transform_keys(&:to_s) }
    end

    # The sessions the loader read, as it read them (see Reported::Session).
    def sessions(reported)
      reported.sessions.map do |s|
        { 'collector' => s.collector, 'session_id' => s.session_id, 'reports' => s.reports }
      end
    end

    def nodes(reported)
      return { 'total' => 0, 'by_collector' => {}, 'by_environment' => {} } if reported.missing?(NODES_REPORT)

      rows = reported.report(NODES_REPORT)
      {
        'total'          => rows.length,
        'by_collector'   => tally(rows, &:collector),
        'by_environment' => tally(rows, &:environment),
      }
    end

    def tally(rows)
      rows.group_by { |n| yield(n) || UNKNOWN }.sort.to_h.transform_values(&:length)
    end
  end
end
