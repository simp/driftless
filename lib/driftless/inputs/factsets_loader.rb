require 'driftless/inputs/report_loader'
require 'driftless/logger'
require 'driftless/reported_checks'
require 'driftless/scan_error'

module Driftless
  module Inputs
    # Loads the incoming tree for the factsets report, applying the declared
    # environment filter when there is one.
    class FactsetsLoader
      include ReportedChecks

      FACTSETS_REPORT = 'factsets-for-all-active-nodes'.freeze

      # @return [Reported, nil] what the loader read, after the environment
      #   filter; nil until {#load}
      attr_reader :reported

      # @param environments [Array<String>, nil] environments to keep; nil or
      #   empty keeps every node
      # @param allow_missing_envs [Boolean] warn instead of raising when a
      #   listed environment has no reports
      def initialize(incoming_dir:, environments: nil, allow_missing_envs: false)
        @incoming_dir       = incoming_dir
        @environments       = environments
        @allow_missing_envs = allow_missing_envs
      end

      # @return [Array<Node>] rows of the factsets report
      # @raise [ScanError] when the factsets report is absent, or the
      #   environment filter rejects the tree
      def load
        Driftless.logger.info("factsets: reading #{incoming_dir}")
        reported, _findings = ReportLoader.load(incoming_dir)
        if reported.missing?(FACTSETS_REPORT)
          raise ScanError, "no report:#{FACTSETS_REPORT} data under #{incoming_dir.inspect}"
        end
        Driftless.logger.info(
          "factsets: loaded #{reported.report(FACTSETS_REPORT).size} from #{describe_sessions(reported)}",
        )

        if environments&.any?
          reported = apply_environment_filter(reported)
          Driftless.logger.info(
            "factsets: #{reported.report(FACTSETS_REPORT).size} in environments #{environments.join(', ')}",
          )
        end

        @reported = reported
        Array(reported.report(FACTSETS_REPORT))
      end

      private

      def expected_reports
        [FACTSETS_REPORT]
      end

      # The sessions the factsets report was read from, as `collector--session`.
      def describe_sessions(reported)
        names = reported.sessions
          .select { |s| s.reports.include?(FACTSETS_REPORT) }
          .map { |s| "#{s.collector}--#{s.session_id}" }
        names.empty? ? incoming_dir : names.join(', ')
      end
    end
  end
end
