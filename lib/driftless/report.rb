require 'driftless/inputs/report_loader'
require 'driftless/logger'
require 'driftless/reported_checks'
require 'driftless/scan_error'
require 'driftless/utilization'

module Driftless
  # Loads the incoming report tree, runs the acceptance checks over it, and
  # computes fleet utilization.
  class Report
    include ReportedChecks

    # The report utilization is computed from.
    CLASSES_REPORT = 'classes-for-all-active-nodes'.freeze

    # @return [Reported, nil] what the loader read, after the checks and the
    #   environment filter; nil until {#run}
    attr_reader :reported

    # @return [Hash, nil] {Utilization.compute}'s categories; nil until {#run}
    attr_reader :utilization

    def initialize(incoming_dir:, summary_dir: nil, environments: nil,
                   proceed_with_subset_of_configured_envs: false, accept_partial_report_sessions: nil,
                   accept_duplicate_certnames: false)
      @incoming_dir                   = incoming_dir
      @summary_dir                    = summary_dir
      @environments                   = environments
      @proceed_with_subset_of_configured_envs = proceed_with_subset_of_configured_envs
      @accept_partial_report_sessions = accept_partial_report_sessions
      @accept_duplicate_certnames     = accept_duplicate_certnames
    end

    # Loads and checks the incoming tree, then computes utilization.
    #
    # @return [Hash] {Utilization.compute}'s categories
    # @raise [ScanError] on a tree the checks reject, or one missing the
    #   classes report
    def run
      reported, findings = Inputs::ReportLoader.load(incoming_dir)
      findings.each { |f| warn(f.message) }
      check_duplicate_certnames!(reported)
      check_summary_coverage!
      reported = apply_environment_filter(reported) if environments&.any?

      if reported.missing?(CLASSES_REPORT)
        raise ScanError, "no #{CLASSES_REPORT} report loaded from #{incoming_dir} — " \
                         'utilization needs its per-node class lists'
      end

      @reported    = reported
      @utilization = Utilization.compute(reported.report(CLASSES_REPORT))
    end

    private

    def expected_reports
      %w[all-active-nodes classes-for-all-active-nodes]
    end
  end
end
