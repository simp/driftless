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
            warn 'import cleanup: --incoming-dir required (or set reports.incoming_dir in driftless.yaml)'
            print_help($stderr)
            exit 2
          end

          summary_dir =
            if @options[:summary_dir]
              File.expand_path(@options[:summary_dir])
            else
              File.join(File.dirname(@options[:incoming_dir]), 'summary')
            end

          Import.run_cleanup(
            'import cleanup',
            incoming_dir: @options[:incoming_dir],
            summary_dir:  summary_dir,
            dry_run:      @options[:dry_run] || false,
            override:     @options[:accept_partial_report_sessions],
          )
          exit 0
        rescue ::Driftless::Import::Error => e
          warn "import cleanup: #{e.message}"
          exit 2
        end

        protected

        def configure_parser(o)
          o.on('-i', '--incoming-dir=DIR',
               'Ingest dir to garden',
               'Default: reports.incoming_dir from driftless.yaml') { |v| @options[:incoming_dir] = v }
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
          { incoming_dir: cfg.dig('reports', 'incoming_dir') }.compact
        end
      end
    end
  end
end
