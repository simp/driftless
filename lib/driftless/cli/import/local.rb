require 'driftless/cli/base'
require 'driftless/cli/import'
require 'driftless/import/local'

module Driftless
  module CLI
    class Import
      class Local < Base
        register_command name: 'local', subcommand_of: Import
        desc 'Import a collector session from a local directory'

        def initialize(parent_options: {})
          super
          @options = config_defaults.merge(@options)
        end

        def execute(argv)
          source = argv.shift
          unless source
            warn 'import local: source path required (session dir or reports root)'
            print_help($stderr)
            exit 2
          end

          @options[:incoming_dir] = File.expand_path(@options[:incoming_dir]) if @options[:incoming_dir]
          unless @options[:incoming_dir]
            warn 'import local: --incoming-dir required (or set scan.incoming_dir in driftless.yaml)'
            print_help($stderr)
            exit 2
          end

          summary_dir =
            if @options[:summary_dir]
              File.expand_path(@options[:summary_dir])
            else
              File.join(File.dirname(@options[:incoming_dir]), 'summary')
            end

          result = ::Driftless::Import::Local.new(
            incoming_dir: @options[:incoming_dir],
            summary_dir:  summary_dir,
            dry_run:      @options[:dry_run]  || false,
            rm_after:     @options[:rm_after] || false,
          ).run(source, session_pref: @options[:session])

          verb = @options[:dry_run] ? 'would import' : 'imported'
          extra = result.skipped_missing.zero? ? '' : " (#{result.skipped_missing} source file(s) missing)"
          Driftless.logger.info(
            "import local: #{verb} #{result.copied} report(s) for session #{result.session_id}#{extra}"
          )
          exit 0
        rescue ::Driftless::Import::Error => e
          warn "import local: #{e.message}"
          exit 2
        end

        protected

        def configure_parser(o)
          o.on('-i', '--incoming-dir=DIR',
               'Target ingest dir',
               'Default: scan.incoming_dir from driftless.yaml') { |v| @options[:incoming_dir] = v }
          o.on('-s', '--summary-dir=DIR',
               'Target summary dir',
               'Default: sibling summary/ of --incoming-dir') { |v| @options[:summary_dir] = v }
          o.on('--session=ID', "Explicit session id or 'latest' (default: latest)") do |v|
            @options[:session] = v
          end
          o.on('--rm-after', 'Remove the session dir after a successful import') { @options[:rm_after] = true }
          o.on('--dry-run',  'Log what would be copied without touching the filesystem') { @options[:dry_run] = true }
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
