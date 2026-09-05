require 'fileutils'
require 'json'
require 'yaml'

require 'driftless/inputs/factsets_loader'
require 'driftless/logger'
require 'driftless/node_selector'
require 'driftless/scan_error'

module Driftless
  module Export
    class Error < StandardError; end

    # Write per-certname factset files consumable by onceover
    # (spec/factsets/<name>.json) and by `puppet lookup --facts FILE`.
    #
    # Source: `report:factsets-for-all-active-nodes` under `incoming_dir`,
    # read by {Driftless::Inputs::FactsetsLoader}, then narrowed by a
    # {Driftless::NodeSelector}.
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

      # @return [Array<String>] warnings the run logged, in emission order
      attr_reader :warnings

      # @param selector [NodeSelector, nil] which nodes to export; nil exports
      #   every node
      # @param environments [Array<String>, nil] environments to keep; nil or
      #   empty exports every node
      # @param proceed_with_subset_of_configured_envs [Boolean] warn instead of
      #   raising when a configured environment has no reports
      def initialize(incoming_dir:, output_dir:, profile:,
                     serialization: nil, selector: nil, limit: nil,
                     environments: nil, proceed_with_subset_of_configured_envs: false)
        raise Error, "unknown profile: #{profile.inspect} (known: #{PROFILES.keys.join(', ')})" unless PROFILES.key?(profile)
        ser = serialization || PROFILES.fetch(profile)[:default_serialization]
        raise Error, "unknown serialization: #{ser.inspect} (known: #{SERIALIZATIONS.join(', ')})" unless SERIALIZATIONS.include?(ser)

        @loader = Inputs::FactsetsLoader.new(
          incoming_dir: incoming_dir, environments: environments, proceed_with_subset_of_configured_envs: proceed_with_subset_of_configured_envs,
        )
        @output_dir    = output_dir
        @profile       = profile
        @serialization = ser
        @selector      = selector || NodeSelector.new
        @limit         = limit
        @warnings      = []
      end

      # @return [Result]
      # @raise [ScanError] when the factsets report is absent, the environment
      #   filter rejects the tree, or the selector needs a report that is absent
      def run
        nodes     = @loader.load
        @warnings = @loader.warnings
        unless @selector.empty?
          nodes = @selector.select(nodes, @loader.reported)
          Driftless.logger.info("export factsets: #{nodes.size} match the selection")
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

      def warn(message)
        @warnings << message
        Driftless.logger.warn(message)
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
