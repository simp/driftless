require 'open3'
require 'time'

require 'driftless/version'
require 'driftless/json_document'
require 'driftless/outputs/json_writer'

module Driftless
  # The document `scan --data-file` writes: everything a finished scan knows
  # that the terminal writers cannot carry — which sessions and nodes it
  # read, the overrides it ran under, the repo revision, its warnings —
  # beside the findings. `site` builds from it (design notes §7).
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
        'repo'              => repo(corpus),
        'environments'      => Array(environments),
        'overrides'         => overrides,
        'sessions'          => sessions(corpus.reported),
        # Fleet description; carried here until `report` exists, then moves
        # to the report document (design notes §7).
        'nodes'             => nodes(corpus.reported),
        'findings'          => finding_rows(findings),
        'warnings'          => warnings.dup,
      }
    end

    # The control repo is what a scan is about, so its description sits here:
    # where it is, which revision, and the hierarchy it declares.
    def repo(corpus)
      {
        'dir'       => corpus.repo_dir,
        'git'       => git_revision(corpus.repo_dir),
        'hierarchy' => hierarchy(corpus.hiera_tiers),
      }
    end

    # The tiers as hiera.yaml declares them, so a reader can show every tier —
    # not only those a finding mentions — with the variables it interpolates.
    def hierarchy(tiers)
      tiers.map do |t|
        { 'name' => t.name, 'backend' => t.backend.to_s, 'line' => t.source_line,
          'paths' => t.path_templates, 'vars' => t.interpolation_vars }
      end
    end

    # The acceptance rules a scan was told to relax, so a reader of the
    # document knows its sessions may be spliced or its inventory partial.
    def overrides_from(scanner)
      partial = scanner.accept_partial_report_sessions
      {
        'accept_partial_report_sessions' => (partial == :bare) ? 'bare' : partial,
        'accept_duplicate_certnames'     => scanner.accept_duplicate_certnames ? true : false,
        'allow_missing_envs'             => scanner.allow_missing_envs ? true : false,
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

    # `{ 'sha', 'branch' }` for the checkout at dir, or nil when dir is not a
    # git work tree or git is not installed. Best effort: a document for a
    # repo that is not under git is still worth writing.
    def git_revision(dir)
      return nil unless dir && File.directory?(dir)

      sha    = git_output(dir, 'rev-parse', 'HEAD')
      branch = git_output(dir, 'rev-parse', '--abbrev-ref', 'HEAD')
      sha ? { 'sha' => sha, 'branch' => branch } : nil
    end

    def git_output(dir, *args)
      out, _err, status = Open3.capture3('git', '-C', dir, *args)
      status.success? ? out.strip : nil
    rescue Errno::ENOENT
      nil
    end
  end
end
