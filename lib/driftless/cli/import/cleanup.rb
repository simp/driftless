require 'driftless/cli/base'
require 'driftless/cli/import'
require 'driftless/import/cleanup'
require 'driftless/inputs/report_loader'

module Driftless
  module CLI
    class Import
      class Cleanup < Base
        register_command name: 'cleanup', subcommand_of: Import
        desc 'Archive superseded sessions and quarantine incomplete ones'

        def execute(argv)
          unless argv.empty?
            fatal!("import cleanup: unexpected arguments: #{argv.inspect}", help: true)
          end

          @options[:incoming_dir] = File.expand_path(@options[:incoming_dir]) if @options[:incoming_dir]
          unless @options[:incoming_dir]
            fatal!('import cleanup: --incoming-dir required (or set reports.incoming_dir in driftless.yaml)', help: true)
          end

          summary_dir =
            if @options[:summary_dir]
              File.expand_path(@options[:summary_dir])
            else
              ::Driftless::Inputs::ReportLoader.summary_dir_for(@options[:incoming_dir])
            end

          Import.run_cleanup(
            'import cleanup',
            incoming_dir: @options[:incoming_dir],
            summary_dir:  summary_dir,
            dry_run:      @options[:dry_run] || false,
            override:     @options[:accept_partial_report_sessions],
            archive:      @options.fetch(:archive, true),
            purge_archive: @options[:purge_archive] || false,
          )
          exit 0
        rescue ::Driftless::Import::Error => e
          fatal!("import cleanup: #{e.message}")
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
          o.on('--[no-]archive',
               'Move superseded sessions to .archive/ (default) or delete them',
               'Default: import.archive_old_reports from driftless.yaml') { |v| @options[:archive] = v }
          o.on('--purge-archive',
               'Delete the existing .archive/ tree before gardening') { @options[:purge_archive] = true }
          Import.declare_accept_partial(o, @options)
        end

        private

        def config_defaults
          cfg = ::Driftless.config
          { incoming_dir: cfg.dig('reports', 'incoming_dir'),
            archive:      cfg.dig('import', 'archive_old_reports') }.compact
        end
      end
    end
  end
end
