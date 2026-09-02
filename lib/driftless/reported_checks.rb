require 'set'

require 'driftless/config_keys'
require 'driftless/inputs/report_loader'
require 'driftless/inputs/summary_index'
require 'driftless/logger'
require 'driftless/reported'
require 'driftless/scan_error'

module Driftless
  # Acceptance checks on the loaded report tree
  module ReportedChecks
    extend ConfigKeys::DSL

    config_key 'puppet.environments', type: :array, default: [],
                about: 'Puppet environment(s) to scan.  Generally your main production environment; multiple values are accepted to acommodate multi-tenant/site variations'
    config_key 'puppet.allow_missing_envs', type: :boolean, default: false,
               about: 'Warn instead of erroring when a listed environment has no reports'
    config_key 'reports.accept_duplicate_certnames', type: :boolean, default: false,
               about: 'Warn instead of erroring when one certname is reported by two collectors'

    attr_reader :incoming_dir, :summary_dir, :environments, :allow_missing_envs,
                :accept_partial_report_sessions, :accept_duplicate_certnames

    # @return [Array<String>] warnings the run logged, in emission order, so
    #   the CLI can replay them after its output
    def warnings
      @warnings ||= []
    end

    private

    # @return [Array<String>] the reports the run needs; the coverage check
    #   compares each collector's session summary against them
    def expected_reports
      raise NotImplementedError, "#{self.class} must define expected_reports"
    end

    # Logs the warning now and records it in {#warnings} for end-of-run replay.
    def warn(message)
      warnings << message
      Driftless.logger.warn(message)
    end

    # Compares each collector's latest session summary against {#expected_reports}.
    #
    # No summaries on disk is a no-op: nothing to compare against.
    # Bare --accept-partial-report-sessions skips the check;
    # a list (=A,B,C) becomes the expected set and downgrades gaps to
    # warnings.
    #
    # @raise [ScanError] on a gap, unless permittd by
    #   --accept-partial-report-sessions
    def check_summary_coverage!
      return unless summary_dir

      expected =
        case accept_partial_report_sessions
        when :bare  then return
        when Array  then accept_partial_report_sessions.map(&:to_s).uniq.sort
        else             expected_reports
        end
      return if expected.empty?

      latest = Inputs::SummaryIndex.latest_per_collector(summary_dir)
      return if latest.empty?

      strict = accept_partial_report_sessions.nil?
      gaps = latest.each_with_object({}) do |(collector, entry), acc|
        missing = expected.reject do |r|
          e = entry.reports_declared[r]
          e.is_a?(Hash) && e['status'] == 'ok'
        end
        acc[collector] = missing unless missing.empty?
      end
      return if gaps.empty?

      per_collector = gaps.map { |c, m| "#{c} missing #{m.join(',')}" }.join('; ')
      if strict
        raise ScanError,
              "collector coverage gap: #{per_collector} " \
              "(run `driftless import cleanup` to garden #{incoming_dir}, " \
              'or pass --accept-partial-report-sessions)'
      else
        gaps.each do |collector, missing|
          warn(
            "collector #{collector} missing expected reports #{missing.inspect} " \
            '(accepting partial session per --accept-partial-report-sessions)',
          )
        end
      end
    end

    def check_duplicate_certnames!(reported)
      dups = reported.duplicate_certnames
      return if dups.nil? || dups.empty?

      described = dups.map { |certname, collectors| "#{certname} (#{collectors.join(', ')})" }

      unless accept_duplicate_certnames
        raise ScanError,
              "certname reported by more than one collector: #{described.join('; ')} " \
              '— an agent belongs to one PuppetDB ecosystem, so the report set is ' \
              'inconsistent and findings drawn from it cannot be trusted. Investigate ' \
              'the collectors, or pass --accept-duplicate-certnames to proceed anyway.'
      end

      dups.each do |certname, collectors|
        warn(
          "certname #{certname.inspect} reported by #{collectors.length} collectors " \
          "(#{collectors.join(', ')}); keeping the newest record " \
          '(accepted per accept_duplicate_certnames)',
        )
      end
    end

    def apply_environment_filter(reported)
      # Precedes the env-mismatch loop so an empty inventory reads as
      # "no node reports" rather than as a puppet.environments misconfiguration.
      if Inputs::ReportLoader::NODE_REPORTS.all? { |q| reported.missing?(q) }
        msg = "no PuppetDB node reports loaded from #{incoming_dir} " \
              '(expected <query>/<collector>--<timestamp>.{json,ndjson} ' \
              "files under at least one of: #{Inputs::ReportLoader::NODE_REPORTS.join(', ')})"
        raise ScanError, msg unless allow_missing_envs
        warn(msg)
        return reported
      end

      env_set   = Set.new(environments)
      seen_envs = Set.new

      filtered_data = {}
      Inputs::ReportLoader::QUERIES.each do |query|
        next if reported.missing?(query)

        kept = reported.report(query).select do |node|
          env = node.environment
          if env.nil?
            true
          elsif env_set.include?(env)
            seen_envs << env
            true
          else
            Driftless.logger.info("  node #{node.certname.inspect} excluded (environment #{env.inspect} not in puppet.environments)")
            false
          end
        end
        filtered_data[query] = kept
      end

      (env_set - seen_envs).each do |env|
        msg = "environment #{env.inspect} listed in puppet.environments but has no reports in #{incoming_dir}"
        raise ScanError, msg unless allow_missing_envs
        warn(msg)
      end

      Reported.new(data: filtered_data, duplicate_certnames: reported.duplicate_certnames,
                   sessions: reported.sessions)
    end
  end
end
