require 'open3'
require 'time'

require 'driftless/version'
require 'driftless/inputs/summary_index'
require 'driftless/outputs/json_writer'

module Driftless
  # The static site `driftless site` builds from a finished scan.
  module Site
    # The data one site build consumes: a finished scan assembled into a
    # single JSON-ready Hash. Findings alone cannot say which nodes and
    # collectors the scan saw, what it warned about, or which repo revision it
    # ran against, so those are gathered here beside them. Embedded in
    # index.html and written beside it as data.json (design notes §7).
    module BuildData
      SCHEMA_VERSION = 1

      # The report whose rows are counted for `nodes`.
      NODES_REPORT = 'all-active-nodes'.freeze

      # Key under which nodes with no collector or environment are tallied.
      UNKNOWN = '(unknown)'.freeze

      module_function

      # @param findings [Array<Finding>] what {Scan#run} returned
      # @param corpus [Corpus] {Scan#corpus} after the run
      # @param warnings [Array<String>] {Scan#warnings}
      # @param environments [Array<String>, nil] the environments scanned
      # @param summary_dir [String, nil] collector session summaries, as the
      #   scan's coverage check read them
      # @param now [Time] stamp for `generated_at`; injectable for specs
      # @return [Hash] string-keyed, ready for JSON.generate
      def assemble(findings:, corpus:, warnings:, environments:, summary_dir:, now: Time.now)
        {
          'schema_version'    => SCHEMA_VERSION,
          'generated_at'      => now.utc.iso8601,
          'driftless_version' => VERSION,
          'repo'              => { 'dir' => corpus.repo_dir, 'git' => git_revision(corpus.repo_dir) },
          'environments'      => Array(environments),
          'sessions'          => sessions(summary_dir),
          'nodes'             => nodes(corpus.reported),
          'findings'          => finding_rows(findings),
          'utilization'       => nil,
          'warnings'          => warnings.dup,
        }
      end

      # Same order as the JSON writer, so data.json and `-f json` agree.
      def finding_rows(findings)
        findings
          .sort_by { |f| [f.key, f.path.to_s, f.line || 0] }
          .map { |f| Outputs::JsonWriter.finding_to_h(f).transform_keys(&:to_s) }
      end

      # One entry per collector, newest session, in collector order.
      def sessions(summary_dir)
        Inputs::SummaryIndex.latest_per_collector(summary_dir).values
          .sort_by(&:collector)
          .map do |e|
            { 'collector' => e.collector, 'session_id' => e.session_id,
              'reports_declared' => e.reports_declared }
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
      # git work tree or git is not installed. Best effort: a page for a
      # repo that is not under git is still worth building.
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
end
