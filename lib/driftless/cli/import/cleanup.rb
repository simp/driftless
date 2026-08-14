require 'driftless/cli/base'
require 'driftless/cli/import'
require 'driftless/import/cleanup'

module Driftless
  module CLI
    class Import
      class Cleanup < Base
        register_command name: 'cleanup', subcommand_of: Import
        desc 'Archive superseded sessions and quarantine incomplete ones'

        def initialize(parent_options: {})
          super
          @options = config_defaults.merge(@options)
        end

        def execute(argv)
          unless argv.empty?
            warn "import cleanup: unexpected arguments: #{argv.inspect}"
            print_help($stderr)
            exit 2
          end

          @options[:incoming_dir] = File.expand_path(@options[:incoming_dir]) if @options[:incoming_dir]
          unless @options[:incoming_dir]
            warn 'import cleanup: --incoming-dir required (or set scan.incoming_dir in driftless.yaml)'
            print_help($stderr)
            exit 2
          end

          summary_dir =
            if @options[:summary_dir]
              File.expand_path(@options[:summary_dir])
            else
              File.join(File.dirname(@options[:incoming_dir]), 'summary')
            end

          expected_reports, accept_missing_summary =
            case @options[:accept_partial_report_sessions]
            when :bare  then [[], true]
            when Array  then [@options[:accept_partial_report_sessions], false]
            else             [nil, false]
            end

          result = ::Driftless::Import::Cleanup.new(
            incoming_dir:           @options[:incoming_dir],
            summary_dir:            summary_dir,
            dry_run:                @options[:dry_run] || false,
            expected_reports:       expected_reports,
            accept_missing_summary: accept_missing_summary,
          ).run

          verb = @options[:dry_run] ? 'would ' : ''
          Driftless.logger.info(
            "import cleanup: #{verb}kept #{result.live.size} live, " \
            "#{verb}archived #{result.archived.size}, " \
            "#{verb}quarantined #{result.quarantined.size}"
          )
          result.quarantined.each do |q|
            Driftless.logger.warn(
              "import cleanup: quarantined #{q.collector}--#{q.session_id} (#{q.reason})"
            )
          end
          exit 0
        rescue ::Driftless::Import::Error => e
          warn "import cleanup: #{e.message}"
          exit 2
        end

        protected

        def configure_parser(o)
          o.on('-i', '--incoming-dir=DIR',
               'Ingest dir to garden',
               'Default: scan.incoming_dir from driftless.yaml') { |v| @options[:incoming_dir] = v }
          o.on('-s', '--summary-dir=DIR',
               'Summary dir to garden',
               'Default: sibling summary/ of --incoming-dir') { |v| @options[:summary_dir] = v }
          o.on('--dry-run',
               'Log what would be moved without touching the filesystem') { @options[:dry_run] = true }
          Import.declare_accept_partial(o, @options)
        end

        private

        def config_defaults
          cfg = ::Driftless.config
          { incoming_dir: cfg.dig('scan', 'incoming_dir') }.compact
        end
      end
    end
  end
end
