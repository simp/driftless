require 'fileutils'
require 'json'
require 'set'

require 'driftless/logger'
require 'driftless/detectors'
require 'driftless/config_keys'

module Driftless
  module Import
    class Error < StandardError; end unless defined?(Error)

    # Classifies sessions under <incoming-dir>/<summary-dir> as live,
    # archived, or quarantined. A session is complete when its summary lists
    # every expected report with status:ok and each has a matching file on
    # disk; anything else quarantines. Per collector, the newest complete
    # session stays live and older complete ones move to .archive, or are
    # deleted when `archive:` is false. Whole sessions move together — no
    # cross-session splicing.
    #
    # `expected_reports:` overrides the default set (union of enabled
    # detectors' `requires_reports`); `[]` accepts any set.
    # `accept_missing_summary:` treats sessions with no summary as complete
    # for the presence/status checks.
    # `purge_archive:` removes the existing .archive tree before the pass.
    class Cleanup
      extend ConfigKeys::DSL

      config_key 'import.archive_old_reports', type: :boolean, default: true,
                 about: 'Keep superseded sessions under incoming/.archive/ (false deletes them)'

      SessionResult = Struct.new(:collector, :session_id, :reports_moved,
                                 :summary_moved, :reason, keyword_init: true)
      # `purged` is the count of files removed from .archive, or nil when no
      # purge was requested.
      Result = Struct.new(:live, :archived, :quarantined, :dry_run, :archive, :purged,
                          keyword_init: true)

      def initialize(incoming_dir:, summary_dir:, dry_run: false,
                     expected_reports: nil, accept_missing_summary: false, archive: true,
                     purge_archive: false)
        @incoming_dir           = incoming_dir
        @summary_dir            = summary_dir
        @dry_run                = dry_run
        @expected_reports       = expected_reports
        @accept_missing_summary = accept_missing_summary
        @archive                = archive
        @purge_archive          = purge_archive
      end

      def run
        raise Error, 'incoming_dir required' if @incoming_dir.nil? || @incoming_dir.empty?
        raise Error, 'summary_dir required'  if @summary_dir.nil?  || @summary_dir.empty?

        purged       = @purge_archive ? purge_archive : nil
        expected     = (@expected_reports || derive_expected_reports).map(&:to_s).uniq.sort
        summaries    = discover_summaries
        reports_disk = discover_reports_on_disk
        sessions     = merge_sessions(summaries, reports_disk)

        classify!(sessions, expected)
        supersede!(sessions)

        Driftless.logger.info(
          "import cleanup: incoming=#{@incoming_dir} summary=#{@summary_dir}" \
          "#{' (dry-run)' if @dry_run}",
        )

        live        = []
        archived    = []
        quarantined = []

        sessions.each do |session|
          case session[:verdict]
          when :live
            live << SessionResult.new(collector: session[:collector], session_id: session[:session_id],
                                      reports_moved: 0, summary_moved: 0, reason: nil)
          when :archive
            r, s =
              if @archive
                move_session(session, dest_root: File.join(@incoming_dir, '.archive'))
              else
                delete_session(session)
              end
            archived << SessionResult.new(collector: session[:collector], session_id: session[:session_id],
                                          reports_moved: r, summary_moved: s, reason: nil)
          when :quarantine
            r, s = move_session(session, dest_root: File.join(@incoming_dir, '.quarantine'))
            quarantined << SessionResult.new(collector: session[:collector], session_id: session[:session_id],
                                             reports_moved: r, summary_moved: s, reason: session[:reason])
          end
        end

        Result.new(live: live, archived: archived, quarantined: quarantined,
                   dry_run: @dry_run, archive: @archive, purged: purged)
      end

      private

      def derive_expected_reports
        Detectors.expected_reports
      end

      def discover_summaries
        result = {}
        return result unless File.directory?(@summary_dir)
        Dir.children(@summary_dir).each do |name|
          next if name.start_with?('.')
          next unless name.end_with?('.json')
          path = File.join(@summary_dir, name)
          next unless File.file?(path)

          summary =
            begin
              JSON.parse(File.read(path))
            rescue JSON::ParserError => e
              Driftless.logger.warn("import cleanup: invalid summary #{path}: #{e.message}")
              nil
            end
          next unless summary.is_a?(Hash)
          collector  = summary['collector']
          session_id = summary['session_id']
          next unless collector && session_id

          result[[collector, session_id]] = {
            summary_path:     path,
            reports_declared: summary['reports'] || {},
          }
        end
        result
      end

      def discover_reports_on_disk
        result = Hash.new { |h, k| h[k] = {} }
        return result unless File.directory?(@incoming_dir)
        Dir.children(@incoming_dir).each do |query|
          next if query.start_with?('.')
          query_dir = File.join(@incoming_dir, query)
          next unless File.directory?(query_dir)

          Dir.children(query_dir).each do |file|
            next if file.start_with?('.')
            path = File.join(query_dir, file)
            next unless File.file?(path)
            base = File.basename(file, '.*')
            collector, session_id = base.split('--', 2)
            next unless collector && session_id
            result[[collector, session_id]][query] = path
          end
        end
        result
      end

      def merge_sessions(summaries, reports_disk)
        keys = summaries.keys | reports_disk.keys
        keys.map do |(collector, session_id)|
          {
            collector:       collector,
            session_id:      session_id,
            summary:         summaries[[collector, session_id]],
            reports_on_disk: reports_disk[[collector, session_id]] || {},
          }
        end
      end

      def classify!(sessions, expected)
        sessions.each do |session|
          reason = classification_reason(session, expected)
          session[:verdict] = reason ? :quarantine : :complete
          session[:reason]  = reason
        end
      end

      # Returns nil when the session is complete, or a short reason string on
      # the first failure. Two checks: every expected report is declared
      # status:ok in the summary, and every declared-ok report has a matching
      # file on disk.
      def classification_reason(session, expected)
        summary = session[:summary]
        return 'no _summary.json' unless summary || @accept_missing_summary

        declared = summary ? summary[:reports_declared] : {}

        expected.each do |report|
          entry = declared[report]
          return "expected report #{report.inspect} not listed in summary" unless entry
          return "expected report #{report.inspect} status #{entry['status'].inspect}" unless entry['status'] == 'ok'
        end

        declared.each do |report, entry|
          next unless entry.is_a?(Hash) && entry['status'] == 'ok'
          next if session[:reports_on_disk].key?(report)
          return "summary lists #{report.inspect} status:ok but no file on disk"
        end

        nil
      end

      def supersede!(sessions)
        sessions.group_by { |s| s[:collector] }.each_value do |group|
          completes = group.select { |s| s[:verdict] == :complete }
          next if completes.empty?
          winner = completes.max_by { |s| s[:session_id] }
          completes.each do |s|
            s[:verdict] = s.equal?(winner) ? :live : :archive
          end
        end
      end

      def move_session(session, dest_root:)
        dest_dir = File.join(dest_root, "#{session[:collector]}--#{session[:session_id]}")
        reports  = session[:reports_on_disk]
        summary  = session[:summary]

        if @dry_run
          Driftless.logger.info(
            "import cleanup: would move #{session[:collector]}--#{session[:session_id]} -> #{dest_dir}",
          )
          return [reports.size, summary ? 1 : 0]
        end

        FileUtils.mkdir_p(dest_dir)
        reports_moved = 0
        reports.each do |report, path|
          FileUtils.mv(path, File.join(dest_dir, "#{report}.ndjson"))
          reports_moved += 1
        end
        summary_moved = 0
        if summary
          FileUtils.mv(summary[:summary_path], File.join(dest_dir, '_summary.json'))
          summary_moved = 1
        end
        Driftless.logger.debug(
          "import cleanup: moved #{session[:collector]}--#{session[:session_id]} " \
          "(#{reports_moved} report, #{summary_moved} summary) -> #{dest_dir}",
        )
        [reports_moved, summary_moved]
      end

      # Removes a session's report and summary files. Returns
      # [reports_removed, summary_removed] with the same shape as move_session.
      def delete_session(session)
        label   = "#{session[:collector]}--#{session[:session_id]}"
        reports = session[:reports_on_disk]
        summary = session[:summary]

        if @dry_run
          Driftless.logger.info("import cleanup: would delete #{label}")
          return [reports.size, summary ? 1 : 0]
        end

        reports.each_value { |path| FileUtils.rm_f(path) }
        FileUtils.rm_f(summary[:summary_path]) if summary
        Driftless.logger.debug(
          "import cleanup: deleted #{label} (#{reports.size} report, #{summary ? 1 : 0} summary)",
        )
        [reports.size, summary ? 1 : 0]
      end

      # Removes <incoming-dir>/.archive in full. Returns the number of regular
      # files it held (0 when absent).
      def purge_archive
        dir   = File.join(@incoming_dir, '.archive')
        files = Dir.glob(File.join(dir, '**', '*')).count { |f| File.file?(f) }
        return 0 unless File.directory?(dir)

        if @dry_run
          Driftless.logger.info("import cleanup: would purge #{dir} (#{files} file(s))")
          return files
        end

        FileUtils.rm_rf(dir)
        Driftless.logger.info("import cleanup: purged #{dir} (#{files} file(s))")
        files
      end
    end
  end
end
