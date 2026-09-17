module Driftless
  module Inputs
    # Every report file under an incoming tree: live, archived by
    # `import cleanup`, or quarantined by it.
    class ReportIndex
      # One report file.
      #
      # @!attribute [r] state
      #   @return [String] "live", "archive", or "quarantine"
      # @!attribute [r] collector
      #   @return [String]
      # @!attribute [r] session_id
      #   @return [String]
      # @!attribute [r] report
      #   @return [String] the report name, e.g. "all-active-nodes"
      # @!attribute [r] path
      #   @return [String] absolute
      # @!attribute [r] bytes
      #   @return [Integer] file size
      Entry = Data.define(:state, :collector, :session_id, :report, :path, :bytes)

      STATES = { 'archive' => '.archive', 'quarantine' => '.quarantine' }.freeze
      EXTENSIONS = %w[.json .ndjson].freeze

      # @return [Array<Entry>] live first, then archive, then quarantine;
      #   within a state by collector, session, and report
      def self.list(incoming_dir)
        new(incoming_dir).list
      end

      def initialize(incoming_dir)
        @incoming_dir = incoming_dir
      end

      def list
        entries = live_entries
        STATES.each { |state, dirname| entries.concat(session_entries(state, File.join(@incoming_dir, dirname))) }
        entries
      end

      private

      # `<report>/<collector>--<session>.{json,ndjson}`; dot-prefixed names skipped.
      def live_entries
        Dir.children(@incoming_dir).sort.flat_map do |report|
          dir = File.join(@incoming_dir, report)
          next [] if report.start_with?('.') || !File.directory?(dir)
          Dir.children(dir).sort.filter_map do |name|
            next if name.start_with?('.') || !EXTENSIONS.include?(File.extname(name))
            collector, session_id = File.basename(name, '.*').split('--', 2)
            next unless collector && session_id
            entry('live', collector, session_id, report, File.join(dir, name))
          end
        end
      end

      # `<collector>--<session>/<report>.{json,ndjson}`; `_summary.json` is not a report.
      def session_entries(state, root)
        return [] unless File.directory?(root)
        Dir.children(root).sort.flat_map do |session|
          dir = File.join(root, session)
          collector, session_id = session.split('--', 2)
          next [] unless collector && session_id && File.directory?(dir)
          Dir.children(dir).sort.filter_map do |name|
            next if name.start_with?('_') || !EXTENSIONS.include?(File.extname(name))
            entry(state, collector, session_id, File.basename(name, '.*'), File.join(dir, name))
          end
        end
      end

      def entry(state, collector, session_id, report, path)
        Entry.new(state: state, collector: collector, session_id: session_id, report: report,
                  path: path, bytes: File.size(path))
      end
    end
  end
end
