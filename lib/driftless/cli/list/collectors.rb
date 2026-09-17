require 'driftless/cli/base'
require 'driftless/cli/list'
require 'driftless/cli/table'
require 'driftless/inputs/report_loader'
require 'driftless/inputs/summary_index'

module Driftless
  module CLI
    class List
      # `driftless list collectors`
      #
      # One row per collector with reports in the incoming tree: the session
      # read, its node count, the reports it supplied, and what its summary
      # declares.
      class Collectors < Base
        include Table

        register_command name: 'collectors', subcommand_of: List
        desc 'List collectors found in the incoming report tree'

        COLUMNS = %w[collector session nodes reports summary].freeze

        def execute(_argv)
          require_incoming_dir!
          incoming_dir = File.expand_path(@options[:incoming_dir])
          summary_dir  = @options[:summary_dir] || ::Driftless::Inputs::ReportLoader.summary_dir_for(incoming_dir)

          reported, findings = ::Driftless::Inputs::ReportLoader.load(incoming_dir)
          findings.each { |f| ::Driftless.logger.warn(f.message) }
          summaries = ::Driftless::Inputs::SummaryIndex.latest_per_collector(File.expand_path(summary_dir))

          rows = reported.sessions.map do |session|
            [session.collector, session.session_id, node_count(reported, session.collector).to_s,
             session.reports.join(','), summary_status(summaries[session.collector])]
          end
          print_table(COLUMNS, rows)
          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-i', '--incoming-dir=DIR',
               'Path to the incoming PuppetDB reports directory tree',
               'Default: reports.incoming_dir from driftless.yaml') { |v| @options[:incoming_dir] = v }
          o.on('-s', '--summary-dir=DIR',
               'Path to the summary/ tree written by `driftless import`',
               'Default: sibling summary/ of --incoming-dir') { |v| @options[:summary_dir] = v }
        end

        private

        def require_incoming_dir!
          return if @options[:incoming_dir]
          fatal!('list collectors: --incoming-dir required (or set reports.incoming_dir in driftless.yaml)', help: true)
        end

        def config_defaults
          { incoming_dir: ::Driftless.config.dig('reports', 'incoming_dir') }.compact
        end

        # Nodes the collector reported, from the inventory when present and
        # the factsets report otherwise.
        def node_count(reported, collector)
          ::Driftless::Inputs::ReportLoader::NODE_REPORTS.each do |query|
            next if reported.missing?(query)
            return reported.report(query).count { |n| n.collector == collector }
          end
          0
        end

        # `ok` when every declared report is ok, else the failed count, or
        # `(none)` without a summary.
        def summary_status(entry)
          return '(none)' unless entry
          failed = entry.reports_declared.count { |_, e| !(e.is_a?(Hash) && e['status'] == 'ok') }
          failed.zero? ? 'ok' : "#{failed} failed"
        end
      end
    end
  end
end
