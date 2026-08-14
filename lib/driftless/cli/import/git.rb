require 'driftless/cli/base'
require 'driftless/cli/import'
require 'driftless/import/git'

module Driftless
  module CLI
    class Import
      class Git < Base
        register_command name: 'git', subcommand_of: Import
        desc 'Import collector sessions from a git remote (populated by driftless-store-reports-in-git)'
        positional '<repo-url>'

        def initialize(parent_options: {})
          super
          @options = { branch_prefix: 'collector' }.merge(config_defaults).merge(@options)
        end

        def execute(argv)
          repo_url = argv.shift
          unless repo_url
            warn 'import git: repo URL required'
            print_help($stderr)
            exit 2
          end

          @options[:incoming_dir] = File.expand_path(@options[:incoming_dir]) if @options[:incoming_dir]
          unless @options[:incoming_dir]
            warn 'import git: --incoming-dir required (or set scan.incoming_dir in driftless.yaml)'
            print_help($stderr)
            exit 2
          end

          summary_dir =
            if @options[:no_summaries]
              nil
            elsif @options[:summary_dir]
              File.expand_path(@options[:summary_dir])
            else
              File.join(File.dirname(@options[:incoming_dir]), 'summary')
            end

          begin
            result = ::Driftless::Import::Git.new(
              repo_url:      repo_url,
              incoming_dir:  @options[:incoming_dir],
              summary_dir:   summary_dir,
              branch_prefix: @options[:branch_prefix],
              collector:     @options[:collector],
              dry_run:       @options[:dry_run] || false,
            ).run

            verb = @options[:dry_run] ? 'would import' : 'imported'
            Driftless.logger.info(
              "import git: #{verb} #{result.reports_copied} report file(s) " \
              "and #{result.summaries_copied} summary file(s) " \
              "from #{result.branches_imported} branch(es)"
            )
          rescue ::Driftless::Import::Error => e
            warn "import git: #{e.message}"
            exit 2
          end

          if summary_dir
            begin
              Import.run_cleanup(
                'import git: cleanup',
                incoming_dir: @options[:incoming_dir],
                summary_dir:  summary_dir,
                dry_run:      @options[:dry_run] || false,
                override:     @options[:accept_partial_report_sessions],
              )
            rescue ::Driftless::Import::Error => e
              warn "import git: cleanup failed: #{e.message}"
              exit 2
            end
          else
            Driftless.logger.info('import git: cleanup skipped (--no-summaries)')
          end

          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-i', '--incoming-dir=DIR',
               'Target ingest dir',
               'Default: scan.incoming_dir from driftless.yaml') { |v| @options[:incoming_dir] = v }
          o.on('-s', '--summary-dir=DIR',
               'Target summary dir',
               'Default: sibling summary/ of --incoming-dir') { |v| @options[:summary_dir] = v }
          o.on('--branch-prefix=PREFIX',
               "Import branches under this prefix (default: '#{@options[:branch_prefix]}')") { |v| @options[:branch_prefix] = v }
          o.on('--collector=NAME',
               'Import only <branch-prefix>/<NAME>')                                        { |v| @options[:collector] = v }
          o.on('--no-summaries', 'Skip the summary/ tree')                                  { @options[:no_summaries] = true }
          o.on('--dry-run',      'Log what would be copied without touching the filesystem') { @options[:dry_run] = true }
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
