require 'set'

module Driftless
  # What ReportLoader read from the incoming tree: the rows of each report,
  # the sessions they came from, and the certnames more than one collector
  # claimed. Detectors query it through the Corpus.
  class Reported
    MissingReport = Object.new.freeze

    # One collector session the loader read, and which reports it read from
    # it. Under `import cleanup`'s acceptance rule the live tree holds one
    # complete session per collector, so a collector appearing twice means
    # `--accept-partial-report-sessions` let the loader splice sessions.
    #
    # @!attribute [rw] collector
    #   @return [String]
    # @!attribute [rw] session_id
    #   @return [String] the `<session-id>` half of the report filenames
    # @!attribute [rw] reports
    #   @return [Array<String>] report names read from this session, sorted
    Session = Struct.new(:collector, :session_id, :reports, keyword_init: true)

    # @param duplicate_certnames [Hash{String => Array<String>}] certnames more
    #   than one collector reported, mapped to the collectors that claimed them.
    # @param sessions [Array<Session>] the sessions the loader read, sorted by
    #   collector then session_id
    def initialize(data: {}, duplicate_certnames: {}, sessions: [])
      @data                = data
      @duplicate_certnames = duplicate_certnames
      @sessions            = sessions
    end

    attr_reader :duplicate_certnames, :sessions

    def report(query_name)
      @data.fetch(query_name, MissingReport)
    end

    def missing?(query_name)
      report(query_name).equal?(MissingReport)
    end

    # @return [Set<String>] every class name an active node is classified
    #   with, downcased to fqnames; empty when the classes report is missing
    def all_active_classes
      @all_active_classes ||=
        if missing?('classes-for-all-active-nodes')
          Set.new
        else
          report('classes-for-all-active-nodes').flat_map(&:classes).map(&:downcase).to_set
        end
    end
  end
end
