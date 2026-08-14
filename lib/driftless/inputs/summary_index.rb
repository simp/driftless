require 'json'

require 'driftless/logger'

module Driftless
  module Inputs
    # Read-only lens over a `<summary-dir>` populated by import (Local/Git).
    # Filenames follow `<collector>--<session-id>.json`. Dot-prefixed entries
    # (e.g. `.archive/`) are ignored to stay consistent with ReportLoader.
    class SummaryIndex
      Entry = Struct.new(:collector, :session_id, :path, :reports_declared,
                         keyword_init: true)

      def self.latest_per_collector(summary_dir)
        new(summary_dir).latest_per_collector
      end

      def initialize(summary_dir)
        @summary_dir = summary_dir
      end

      # Returns { collector => Entry } — one entry per collector, whichever
      # session_id sorts highest. Missing/empty summary_dir yields {}.
      def latest_per_collector
        return {} unless @summary_dir && File.directory?(@summary_dir)

        winners = {}
        each_entry do |entry|
          existing = winners[entry.collector]
          winners[entry.collector] = entry if existing.nil? || entry.session_id > existing.session_id
        end
        winners
      end

      private

      def each_entry
        Dir.children(@summary_dir).each do |name|
          next if name.start_with?('.')
          next unless name.end_with?('.json')
          path = File.join(@summary_dir, name)
          next unless File.file?(path)

          base = File.basename(name, '.json')
          collector, session_id = base.split('--', 2)
          next unless collector && session_id

          summary =
            begin
              JSON.parse(File.read(path))
            rescue JSON::ParserError => e
              Driftless.logger.warn("summary index: invalid JSON in #{path}: #{e.message}")
              next
            end
          next unless summary.is_a?(Hash)

          yield Entry.new(
            collector:        collector,
            session_id:       session_id,
            path:             path,
            reports_declared: summary['reports'] || {},
          )
        end
      end
    end
  end
end
