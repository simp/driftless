require 'driftless/inputs/report_loader'
require 'driftless/logger'
require 'driftless/reported_checks'
require 'driftless/scan_error'

module Driftless
  module Inputs
    # Loads the incoming tree for one node report, applying the declared
    # environment filter when there is one.
    class NodeReportLoader
      include ReportedChecks

      FACTSETS_REPORT = 'factsets-for-all-active-nodes'.freeze
      NODES_REPORT    = 'all-active-nodes'.freeze

      # @return [String] the report {#load} returns rows of
      attr_reader :report

      # @return [Reported, nil] what the loader read, after the environment
      #   filter; nil until {#load}
      attr_reader :reported

      # @param environments [Array<String>, nil] environments to keep; nil or
      #   empty keeps every node
      # @param proceed_with_subset_of_configured_envs [Boolean] warn instead of
      #   raising when a configured environment has no reports
      # @param report [String] one of ReportLoader::NODE_REPORTS
      def initialize(incoming_dir:, report: FACTSETS_REPORT, environments: nil,
                     proceed_with_subset_of_configured_envs: false)
        @incoming_dir       = incoming_dir
        @report             = report
        @environments       = environments
        @proceed_with_subset_of_configured_envs = proceed_with_subset_of_configured_envs
      end

      # @return [Array<Node>] rows of the report
      # @raise [ScanError] when the report is absent, or the environment
      #   filter rejects the tree
      def load
        Driftless.logger.info("#{label}: reading #{incoming_dir}")
        reported, _findings = ReportLoader.load(incoming_dir)
        if reported.missing?(report)
          raise ScanError, "no report:#{report} data under #{incoming_dir.inspect}"
        end
        Driftless.logger.info(
          "#{label}: loaded #{reported.report(report).size} from #{describe_sessions(reported)}",
        )

        if environments&.any?
          reported = apply_environment_filter(reported)
          Driftless.logger.info(
            "#{label}: #{reported.report(report).size} in environments #{environments.join(', ')}",
          )
        end

        @reported = reported
        Array(reported.report(report))
      end

      private

      def expected_reports
        [report]
      end

      # The log prefix: `factsets` for the factsets report, else the report name.
      def label
        (report == FACTSETS_REPORT) ? 'factsets' : report
      end

      # The sessions the report was read from, as `collector--session`.
      def describe_sessions(reported)
        names = reported.sessions
          .select { |s| s.reports.include?(report) }
          .map { |s| "#{s.collector}--#{s.session_id}" }
        names.empty? ? incoming_dir : names.join(', ')
      end
    end
  end
end
