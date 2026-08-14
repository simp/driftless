require 'fileutils'
require 'json'
require 'yaml'

require 'driftless/inputs/report_loader'
require 'driftless/logger'

module Driftless
  module Export
    class Error < StandardError; end

    # Write per-certname factset files consumable by onceover
    # (spec/factsets/<name>.json) and by `puppet lookup --facts FILE`.
    #
    # Source: `report:factsets-for-all-active-nodes` under `incoming_dir`,
    # loaded via {Driftless::Inputs::ReportLoader} (same dedupe/winner rules
    # as scan).
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
      Result = Struct.new(:written, :skipped_no_certname, keyword_init: true)

      PROFILES = {
        'onceover' => { default_serialization: 'json' },
        'lookup'   => { default_serialization: 'yaml' },
      }.freeze

      SERIALIZATIONS = %w[json yaml].freeze

      def initialize(incoming_dir:, output_dir:, profile:,
                     serialization: nil, certname_globs: [], limit: nil)
        raise Error, "unknown profile: #{profile.inspect} (known: #{PROFILES.keys.join(', ')})" unless PROFILES.key?(profile)
        ser = serialization || PROFILES.fetch(profile)[:default_serialization]
        raise Error, "unknown serialization: #{ser.inspect} (known: #{SERIALIZATIONS.join(', ')})" unless SERIALIZATIONS.include?(ser)

        @incoming_dir   = incoming_dir
        @output_dir     = output_dir
        @profile        = profile
        @serialization  = ser
        @certname_globs = Array(certname_globs)
        @limit          = limit
      end

      def run
        reported, _findings = Inputs::ReportLoader.load(@incoming_dir)
        if reported.missing?('factsets-for-all-active-nodes')
          raise Error, "no report:factsets-for-all-active-nodes data under #{@incoming_dir.inspect}"
        end

        nodes = Array(reported.report('factsets-for-all-active-nodes'))
        nodes = filter_by_certname(nodes)
        nodes = nodes.sort_by { |n| n.certname.to_s }
        nodes = nodes.first(@limit) if @limit

        FileUtils.mkdir_p(@output_dir)
        written = 0
        skipped_no_certname = 0
        nodes.each do |node|
          if node.certname.nil? || node.certname.to_s.empty?
            skipped_no_certname += 1
            next
          end
          write_one(node)
          written += 1
        end
        Result.new(written: written, skipped_no_certname: skipped_no_certname)
      end

      private

      def filter_by_certname(nodes)
        return nodes if @certname_globs.empty?
        nodes.select do |node|
          @certname_globs.any? { |g| File.fnmatch?(g, node.certname.to_s) }
        end
      end

      def write_one(node)
        path = File.join(@output_dir, "#{node.certname}.#{@serialization}")
        File.write(path, serialize(payload(node)))
      end

      def payload(node)
        facts = deep_dup(node.facts || {})
        add_identity_facts!(facts, node.certname) if @profile == 'lookup'
        facts
      end

      # Mirrors scripts/hiera_lookup.sh in control_repo_model: only fills a key
      # that is absent, so a factset that already carries top-level identity
      # facts is left untouched.
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
