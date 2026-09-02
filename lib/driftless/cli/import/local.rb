require 'driftless/cli/base'
require 'driftless/cli/import'
require 'driftless/import/local'
require 'driftless/inputs/report_loader'

module Driftless
  module CLI
    class Import
      class Local < Base
        register_command name: 'local', subcommand_of: Import
        desc 'Import a collector session from a local directory'
        positional '[<source>]'

        def execute(argv)
          source = argv.shift || @options[:source]
          unless source
            fatal!('import local: source path required (pass a session dir or reports root, ' \
                   'or set import.local.source)', help: true)
          end

          @options[:incoming_dir] = File.expand_path(@options[:incoming_dir]) if @options[:incoming_dir]
          unless @options[:incoming_dir]
            fatal!('import local: --incoming-dir required (or set reports.incoming_dir in driftless.yaml)', help: true)
          end

          summary_dir =
            if @options[:summary_dir]
              File.expand_path(@options[:summary_dir])
            else
              ::Driftless::Inputs::ReportLoader.summary_dir_for(@options[:incoming_dir])
            end

          begin
            result = ::Driftless::Import::Local.new(
              incoming_dir: @options[:incoming_dir],
              summary_dir:  summary_dir,
              dry_run:      @options[:dry_run]  || false,
              rm_after:     @options[:rm_after] || false,
            ).run(source, session_pref: @options[:session])

            verb = @options[:dry_run] ? 'would import' : 'imported'
            extra = result.skipped_missing.zero? ? '' : " (#{result.skipped_missing} source file(s) missing)"
            Driftless.logger.info(
              "import local: #{verb} #{result.copied} report(s) for session #{result.session_id}#{extra}",
            )
          rescue ::Driftless::Import::Error => e
            fatal!("import local: #{e.message}")
          end

          begin
            Import.run_cleanup(
              'import local: cleanup',
              incoming_dir: @options[:incoming_dir],
              summary_dir:  summary_dir,
              dry_run:      @options[:dry_run] || false,
              override:     @options[:accept_partial_report_sessions],
            archive:      @options.fetch(:archive, true),
            )
          rescue ::Driftless::Import::Error => e
            fatal!("import local: cleanup failed: #{e.message}")
          end

          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-i', '--incoming-dir=DIR',
               'Target ingest dir',
               'Default: reports.incoming_dir from driftless.yaml') { |v| @options[:incoming_dir] = v }
          o.on('-s', '--summary-dir=DIR',
               'Target summary dir',
               'Default: sibling summary/ of --incoming-dir') { |v| @options[:summary_dir] = v }
          o.on('--session=ID', "Explicit session id or 'latest' (default: latest)") do |v|
            @options[:session] = v
          end
          o.on('--rm-after', 'Remove the session dir after a successful import') { @options[:rm_after] = true }
          o.on('--dry-run',  'Log what would be copied without touching the filesystem') { @options[:dry_run] = true }
          o.on('--[no-]archive',
               'Move superseded sessions to .archive/ (default) or delete them',
               'Default: import.archive_old_reports from driftless.yaml') { |v| @options[:archive] = v }
          Import.declare_accept_partial(o, @options)
        end

        private

        def config_defaults
          cfg = ::Driftless.config
          { incoming_dir: cfg.dig('reports', 'incoming_dir'),
            source:       cfg.dig('import', 'local', 'source'),
            archive:      cfg.dig('import', 'archive_old_reports') }.compact
        end
      end
    end
  end
end
