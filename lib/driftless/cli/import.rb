require 'driftless/cli/base'
require 'driftless/cli/root'

module Driftless
  module CLI
    class Import < Base
      register_command name: 'import', subcommand_of: Root
      desc 'Import PuppetDB report sessions into the scan ingest tree'

      # Declares `--accept-partial-report-sessions[=A,B,C]` on the parser and
      # stores nil / :bare / Array in options[:accept_partial_report_sessions].
      # Shared by `driftless import`, its subcommands, and `driftless scan`.
      def self.declare_accept_partial(parser, options)
        parser.on('--accept-partial-report-sessions[=REPORTS]', Array,
                  'Accept partial-report sessions',
                  'Bare: any subset + missing summary; List (=A,B,C): expected set = exactly these') do |v|
          options[:accept_partial_report_sessions] = v || :bare
        end
      end

      # Translates the tri-state @options[:accept_partial_report_sessions]
      # into the two independent knobs Import::Cleanup takes.
      # Returns [expected_reports, accept_missing_summary].
      def self.translate_accept_partial(value)
        case value
        when :bare  then [[], true]
        when Array  then [value, false]
        else             [nil, false]
        end
      end

      # Runs Import::Cleanup and narrates the result with the given
      # caller_prefix (e.g. 'import cleanup', 'import local: cleanup').
      # `archive:` false deletes superseded sessions instead of archiving.
      # `purge_archive:` removes the existing .archive tree first.
      # Raises Import::Error on failure — callers wrap with their own
      # rescue-and-exit to attribute the error to the right phase.
      def self.run_cleanup(caller_prefix, incoming_dir:, summary_dir:, dry_run:, override:,
                           archive: true, purge_archive: false)
        require 'driftless/import/cleanup'
        expected_reports, accept_missing_summary = translate_accept_partial(override)
        result = ::Driftless::Import::Cleanup.new(
          incoming_dir:           incoming_dir,
          summary_dir:            summary_dir,
          dry_run:                dry_run,
          expected_reports:       expected_reports,
          accept_missing_summary: accept_missing_summary,
          archive:                archive,
          purge_archive:          purge_archive,
        ).run

        verb = dry_run ? 'would ' : ''
        superseded = result.archive ? 'archived' : 'deleted'
        purged = result.purged ? ", #{verb}purged #{result.purged} archived file(s)" : ''
        Driftless.logger.info(
          "#{caller_prefix}: #{verb}kept #{result.live.size} live, " \
          "#{verb}#{superseded} #{result.archived.size}, " \
          "#{verb}quarantined #{result.quarantined.size}#{purged}",
        )
        result.quarantined.each do |q|
          Driftless.logger.warn(
            "#{caller_prefix}: quarantined #{q.collector}--#{q.session_id} (#{q.reason})",
          )
        end
        result
      end

      protected

      def configure_parser(o)
        self.class.declare_accept_partial(o, @options)
      end
    end
  end
end

Dir[File.join(__dir__, 'import', '*.rb')].sort.each { |f| require f }
