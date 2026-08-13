require 'fileutils'
require 'json'

require 'driftless/logger'

module Driftless
  module Import
    class Error < StandardError; end

    # Copies a driftless-collector session into the ReportLoader ingest layout
    # (<incoming-dir>/<query>/<collector>--<session-id>.ndjson) so `driftless
    # scan -i <incoming-dir>` consumes it directly. No git transport involved;
    # source is a local session directory produced by
    # scripts/driftless-collect-puppetdb-reports.rb.
    class Local
      Result = Struct.new(:copied, :skipped_missing, :collector, :session_id,
                          keyword_init: true)

      def initialize(incoming_dir:, dry_run: false, rm_after: false)
        @incoming_dir = incoming_dir
        @dry_run      = dry_run
        @rm_after     = rm_after
      end

      # source_arg is either a session dir (contains _summary.json directly)
      # or a reports root (contains sessions/<id>/_summary.json subtree).
      # session_pref selects a specific id when source_arg is a reports root;
      # 'latest' or nil picks the lexicographically-last session.
      def run(source_arg, session_pref: nil)
        raise Error, 'source path required' if source_arg.nil? || source_arg.empty?
        raise Error, "not a directory: #{source_arg}" unless File.directory?(source_arg)

        session_dir = discover_session_dir(source_arg, session_pref)
        summary     = read_summary(session_dir)
        collector   = summary.fetch('collector')
        session_id  = summary.fetch('session_id')

        Driftless.logger.info("import local: session #{session_id} collector #{collector}")
        Driftless.logger.info("import local: target #{@incoming_dir}#{@dry_run ? ' (dry-run)' : ''}")

        copied, missing = copy_reports(session_dir, summary, collector, session_id)

        if @rm_after && !@dry_run && copied.positive?
          FileUtils.rm_rf(session_dir)
          Driftless.logger.info("import local: removed session dir #{session_dir}")
        end

        Result.new(
          copied:          copied,
          skipped_missing: missing,
          collector:       collector,
          session_id:      session_id,
        )
      end

      private

      def discover_session_dir(path, session_pref)
        return path if File.file?(File.join(path, '_summary.json'))

        sessions_root = File.join(path, 'sessions')
        unless File.directory?(sessions_root)
          raise Error, "no _summary.json in #{path} and no sessions/ subdir either"
        end

        candidates = Dir.children(sessions_root).select do |name|
          File.file?(File.join(sessions_root, name, '_summary.json'))
        end.sort
        raise Error, "no sessions with _summary.json under #{sessions_root}" if candidates.empty?

        chosen = (session_pref.nil? || session_pref == 'latest') ? candidates.last : session_pref
        unless candidates.include?(chosen)
          tail = candidates.last(5).join(', ')
          tail += ', ...' if candidates.size > 5
          raise Error, "session #{chosen} not found under #{sessions_root} (have: #{tail})"
        end
        File.join(sessions_root, chosen)
      end

      def read_summary(session_dir)
        path = File.join(session_dir, '_summary.json')
        raise Error, "missing _summary.json in #{session_dir}" unless File.file?(path)
        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        raise Error, "invalid _summary.json in #{session_dir}: #{e.message}"
      end

      def copy_reports(session_dir, summary, collector, session_id)
        copied  = 0
        missing = 0
        summary.fetch('reports').each do |report_name, entry|
          src = File.join(session_dir, entry.fetch('file'))
          unless File.file?(src)
            Driftless.logger.warn("import local: report #{report_name} file missing at #{src}; skipping")
            missing += 1
            next
          end
          dst_dir  = File.join(@incoming_dir, report_name)
          dst_path = File.join(dst_dir, "#{collector}--#{session_id}.ndjson")

          if @dry_run
            Driftless.logger.info("import local: would copy #{src} -> #{dst_path}")
          else
            FileUtils.mkdir_p(dst_dir)
            FileUtils.cp(src, dst_path)
            Driftless.logger.debug("import local: copied #{report_name}/#{collector}--#{session_id}.ndjson")
          end
          copied += 1
        end
        [copied, missing]
      end
    end
  end
end
