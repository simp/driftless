require 'fileutils'
require 'json'
require 'yaml'

require 'driftless/inputs/report_loader'
require 'driftless/logger'
require 'driftless/reported_checks'

module Driftless
  module Export
    class Error < StandardError; end

    # Write per-certname factset files consumable by onceover
    # (spec/factsets/<name>.json) and by `puppet lookup --facts FILE`.
    #
    # Source: `report:factsets-for-all-active-nodes` under `incoming_dir`,
    # loaded via {Driftless::Inputs::ReportLoader} (same dedupe/winner rules
    # as scan). When `environments` is given, the same environment filter
    # scan and report apply drops nodes outside it.
    #
    # Profile selects filename convention, default serialization, and whether
    # top-level identity facts (hostname/domain/fqdn/clientcert) are
    # synthesized on export:
    #
    # - `onceover` — raw facts hash; no synthesis. Default serialization: json.
    # - `lookup`   — facts + synthesized identity facts when absent, because
    #                `puppet lookup --facts` refuses factsets missing any of
    #                hostname/domain/fqdn/clientcert at top level, and
    #                PuppetDB inventory stores them under `networking.*`.
    #                Baked in at export time so downstream doesn't need jq.
    #                Default serialization: yaml.
    class Factsets
      include ReportedChecks

      Result = Struct.new(:written, :skipped_no_certname, keyword_init: true)

      FACTSETS_REPORT = 'factsets-for-all-active-nodes'.freeze

      PROFILES = {
        'onceover' => { default_serialization: 'json' },
        'lookup'   => { default_serialization: 'yaml' },
      }.freeze

      SERIALIZATIONS = %w[json yaml].freeze

      # @param environments [Array<String>, nil] environments to keep; nil or
      #   empty exports every node
      # @param allow_missing_envs [Boolean] warn instead of raising when a
      #   listed environment has no reports
      def initialize(incoming_dir:, output_dir:, profile:,
                     serialization: nil, certname_globs: [], limit: nil,
                     environments: nil, allow_missing_envs: false)
        raise Error, "unknown profile: #{profile.inspect} (known: #{PROFILES.keys.join(', ')})" unless PROFILES.key?(profile)
        ser = serialization || PROFILES.fetch(profile)[:default_serialization]
        raise Error, "unknown serialization: #{ser.inspect} (known: #{SERIALIZATIONS.join(', ')})" unless SERIALIZATIONS.include?(ser)

        @incoming_dir       = incoming_dir
        @output_dir         = output_dir
        @profile            = profile
        @serialization      = ser
        @certname_globs     = Array(certname_globs)
        @limit              = limit
        @environments       = environments
        @allow_missing_envs = allow_missing_envs
      end

      # @return [Result]
      # @raise [Error] when the factsets report is absent
      # @raise [ScanError] when the environment filter rejects the tree
      def run
        Driftless.logger.info("export factsets: reading #{@incoming_dir}")
        reported, _findings = Inputs::ReportLoader.load(@incoming_dir)
        if reported.missing?(FACTSETS_REPORT)
          raise Error, "no report:#{FACTSETS_REPORT} data under #{@incoming_dir.inspect}"
        end
        Driftless.logger.info(
          "export factsets: loaded #{reported.report(FACTSETS_REPORT).size} factsets " \
          "from #{describe_sessions(reported)}",
        )

        if environments&.any?
          reported = apply_environment_filter(reported)
          Driftless.logger.info(
            "export factsets: #{reported.report(FACTSETS_REPORT).size} in " \
            "environments #{environments.join(', ')}",
          )
        end

        nodes = Array(reported.report(FACTSETS_REPORT))
        unless @certname_globs.empty?
          nodes = filter_by_certname(nodes)
          Driftless.logger.info("export factsets: #{nodes.size} match --certname #{@certname_globs.join(', ')}")
        end
        nodes = nodes.sort_by { |n| n.certname.to_s }
        if @limit
          nodes = nodes.first(@limit)
          Driftless.logger.info("export factsets: limited to #{nodes.size}")
        end

        FileUtils.mkdir_p(@output_dir)
        written = 0
        skipped_no_certname = 0
        nodes.each do |node|
          if node.certname.nil? || node.certname.to_s.empty?
            skipped_no_certname += 1
            warn("export factsets: skipped a factset from #{node.collector || '(unknown collector)'} with no certname")
            next
          end
          Driftless.logger.debug("export factsets: wrote #{write_one(node)}")
          written += 1
        end
        Result.new(written: written, skipped_no_certname: skipped_no_certname)
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
        names.empty? ? @incoming_dir : names.join(', ')
      end

      def filter_by_certname(nodes)
        nodes.select do |node|
          @certname_globs.any? { |g| File.fnmatch?(g, node.certname.to_s) }
        end
      end

      # @return [String] the path written
      def write_one(node)
        path = File.join(@output_dir, "#{node.certname}.#{@serialization}")
        File.write(path, serialize(payload(node)))
        path
      end

      def payload(node)
        facts = deep_dup(node.facts || {})
        add_identity_facts!(facts, node.certname) if @profile == 'lookup'
        facts
      end

      # Fills each identity fact only where absent; existing top-level values
      # are left untouched.
      def add_identity_facts!(facts, certname)
        net    = facts['networking'].is_a?(Hash) ? facts['networking'] : {}
        fqdn   = net['fqdn'] || certname.to_s
        parts  = fqdn.split('.', 2)
        facts['hostname']   ||= net['hostname'] || parts.first
        facts['domain']     ||= net['domain']   || (parts[1] || '')
        facts['fqdn']       ||= fqdn
        facts['clientcert'] ||= certname.to_s
      end

      def serialize(data)
        case @serialization
        when 'json' then JSON.pretty_generate(data) + "\n"
        when 'yaml' then YAML.dump(data)
        end
      end

      def deep_dup(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
        when Array then obj.map { |v| deep_dup(v) }
        else obj
        end
      end
    end
  end
end
