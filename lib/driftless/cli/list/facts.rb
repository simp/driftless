require 'driftless/cli/base'
require 'driftless/cli/list'
require 'driftless/cli/node_selection'
require 'driftless/cli/table'
require 'driftless/inputs/node_report_loader'
require 'driftless/scan_error'

module Driftless
  module CLI
    class List
      # `driftless list facts`
      #
      # One row per fact path across the selected nodes' factsets: how many
      # nodes carry it and how many distinct values it takes.
      class Facts < Base
        include NodeSelection
        include Table

        register_command name: 'facts', subcommand_of: List
        desc 'List fact paths across reported factsets, with node and value counts'

        COLUMNS = %w[fact nodes values].freeze

        def execute(_argv)
          require_incoming_dir!

          loader = ::Driftless::Inputs::NodeReportLoader.new(
            incoming_dir:       File.expand_path(@options[:incoming_dir]),
            environments:       @options[:environments],
            proceed_with_subset_of_configured_envs: @options[:proceed_with_subset_of_configured_envs] || false,
          )
          nodes    = loader.load
          selector = node_selector
          nodes    = selector.select(nodes, loader.reported) unless selector.empty?

          rows = tally(nodes).map { |path, values| [path, values.length.to_s, values.uniq.length.to_s] }
          print_table(COLUMNS, rows)
          exit 0
        rescue ::Driftless::ScanError => e
          fatal!("list facts: #{e.message}")
        end

        protected

        def option_defaults
          { exclude: [] }
        end

        def configure_parser(o)
          o.on('-i', '--incoming-dir=DIR',
               'Ingest dir holding factsets-for-all-active-nodes/',
               'Default: reports.incoming_dir from driftless.yaml') { |v| @options[:incoming_dir] = v }
          o.on('-x', '--exclude=GLOB', Array,
               'Omit fact paths matching GLOB (repeatable; File.fnmatch syntax,',
               'e.g. "system_uptime.*,memory.*.available*")') { |v| (@options[:exclude] ||= []).concat(v) }

          declare_node_selection(o)

          o.separator ''
          o.separator 'Environment scoping:'
          o.on('--environments=ENVS', Array,
               'Read only nodes in these Puppet environment(s), comma-separated',
               'Default: puppet.environments from driftless.yaml; unset reads every node') do |v|
            @options[:environments] = v
          end
          o.on('-b', '--proceed-with-subset-of-configured-envs',
               'Proceed with the reports for the environments present, even when they',
               'do not cover every environment in puppet.environments') do
            @options[:proceed_with_subset_of_configured_envs] = true
          end
        end

        private

        def require_incoming_dir!
          return if @options[:incoming_dir]
          fatal!('list facts: --incoming-dir required (or set reports.incoming_dir in driftless.yaml)', help: true)
        end

        def config_defaults
          cfg = ::Driftless.config
          {
            incoming_dir:       cfg.dig('reports', 'incoming_dir'),
            environments:       cfg.dig('puppet',  'environments'),
            proceed_with_subset_of_configured_envs: cfg.dig('puppet', 'proceed_with_subset_of_configured_envs'),
          }.compact
        end

        # @return [Hash{String => Array}] path-sorted; one value per node
        #   carrying the path, excluded paths dropped
        def tally(nodes)
          values = Hash.new { |h, k| h[k] = [] }
          nodes.each do |node|
            leaves(node.facts).each do |path, value|
              next if @options[:exclude].any? { |g| File.fnmatch?(g, path, File::FNM_EXTGLOB) }
              values[path] << value
            end
          end
          values.sort.to_h
        end

        # Dot-joined paths to every non-Hash value, arrays included whole.
        def leaves(hash, prefix = nil)
          hash.flat_map do |key, value|
            path = prefix ? "#{prefix}.#{key}" : key.to_s
            value.is_a?(Hash) ? leaves(value, path) : [[path, value]]
          end
        end
      end
    end
  end
end
