require 'time'

require 'driftless/version'
require 'driftless/json_document'

module Driftless
  # The static site `driftless site` builds from the other commands' documents.
  module Site
    # The data one site build consumes: the scan document and, when present,
    # the report document, munged into a single JSON-ready Hash. The two must
    # describe the same collector sessions; {assemble} refuses otherwise.
    # Embedded in index.html and written beside it as data.json (design
    # notes §7).
    module BuildData
      DOCUMENT       = 'site'.freeze
      SCHEMA_VERSION = 1

      module_function

      # @param scan [Hash] a document from {ScanData.read}
      # @param report [Hash, nil] the report document, once `report` exists;
      #   it contributes `utilization` and must agree with scan on sessions
      # @param now [Time] stamp for `generated_at`; injectable for specs
      # @raise [JsonDocument::Error] when scan and report disagree
      def assemble(scan:, report: nil, now: Time.now)
        check_agreement!(scan, report) if report
        {
          'document'          => DOCUMENT,
          'schema_version'    => SCHEMA_VERSION,
          'generated_at'      => now.utc.iso8601,
          'driftless_version' => VERSION,
          'sources'           => { 'scan' => stamp(scan), 'report' => report && stamp(report) },
          'repo'              => scan['repo'],
          'environments'      => scan.fetch('environments', []),
          'overrides'         => scan.fetch('overrides', {}),
          'sessions'          => scan.fetch('sessions', []),
          'nodes'             => scan['nodes'],
          'findings'          => scan.fetch('findings', []),
          'utilization'       => report && report['utilization'],
          'warnings'          => scan.fetch('warnings', []),
        }
      end

      def write(data, path)
        JsonDocument.write(data, path)
      end

      # @raise [JsonDocument::Error]
      def read(path)
        JsonDocument.read(path, document: DOCUMENT, schema_version: SCHEMA_VERSION)
      end

      # When and by which version a source document was written.
      def stamp(doc)
        { 'generated_at' => doc['generated_at'], 'driftless_version' => doc['driftless_version'] }
      end

      # Two documents agree when they read the same (collector, session_id)
      # pairs: the session is the transactional unit, so anything else means
      # the incoming tree changed between the two runs.
      def check_agreement!(scan, report)
        a = session_keys(scan)
        b = session_keys(report)
        return if a == b

        raise JsonDocument::Error,
              'scan and report data disagree on sessions: ' \
              "scan read #{format_sessions(a - b)}, report read #{format_sessions(b - a)}"
      end

      def session_keys(doc)
        doc.fetch('sessions', []).map { |s| [s['collector'], s['session_id']] }.sort
      end

      def format_sessions(keys)
        keys.empty? ? 'nothing the other did not' : keys.map { |c, id| "#{c}@#{id}" }.join(', ')
      end
    end
  end
end
