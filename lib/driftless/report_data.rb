require 'time'

require 'driftless/json_document'
require 'driftless/scan_data'
require 'driftless/version'

module Driftless
  # The document `report --data-file` writes: the utilization a report run
  # computed, beside the sessions, nodes, and overrides it ran under.
  # `site` builds from it and the scan document together.
  module ReportData
    DOCUMENT       = 'report'.freeze
    SCHEMA_VERSION = 1

    # Where `report --data-file` writes and `site` reads when neither is
    # told otherwise; relative to the working directory.
    DEFAULT_PATH = 'public/report.json'.freeze

    module_function

    # @param reporter [Report] populated by {Report#run}
    # @param now [Time] stamp for `generated_at`; injectable for specs
    # @return [Hash] string-keyed, ready for JSON.generate
    def assemble(reporter, now: Time.now)
      {
        'document'          => DOCUMENT,
        'schema_version'    => SCHEMA_VERSION,
        'generated_at'      => now.utc.iso8601,
        'driftless_version' => VERSION,
        # The scan document carries the same three shapes; one
        # implementation keeps the two documents from drifting apart.
        'overrides'         => ScanData.overrides_from(reporter),
        'sessions'          => ScanData.sessions(reporter.reported),
        'nodes'             => ScanData.nodes(reporter.reported),
        'utilization'       => reporter.utilization,
      }
    end

    def write(data, path)
      JsonDocument.write(data, path)
    end

    # @raise [JsonDocument::Error]
    def read(path)
      JsonDocument.read(path, document: DOCUMENT, schema_version: SCHEMA_VERSION)
    end
  end
end
