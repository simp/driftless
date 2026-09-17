require 'driftless/cli/base'
require 'driftless/cli/list'
require 'driftless/cli/node_selection'
require 'driftless/cli/table'
require 'driftless/inputs/node_report_loader'
require 'driftless/scan_error'
require 'driftless/utilization'

module Driftless
  module CLI
    class List
      # `driftless list nodes`
      #
      # One row per active node, narrowed by the node-selection flags.
      class Nodes < Base
        include NodeSelection
        include Table

        register_command name: 'nodes', subcommand_of: List
        desc 'List active nodes by certname, environment, collector, and roles'

        COLUMNS = %w[certname environment collector roles].freeze

        def execute(_argv)
          require_incoming_dir!

          loader = ::Driftless::Inputs::NodeReportLoader.new(
            incoming_dir:       File.expand_path(@options[:incoming_dir]),
            report:             ::Driftless::Inputs::NodeReportLoader::NODES_REPORT,
            environments:       @options[:environments],
            proceed_with_subset_of_configured_envs: @options[:proceed_with_subset_of_configured_envs] || false,
          )
          nodes    = loader.load
          selector = node_selector
          nodes    = selector.select(nodes, loader.reported) unless selector.empty?
          roles_of = roles_by_certname(loader.reported)

          rows = nodes.sort_by { |n| n.certname.to_s }.map do |n|
            [n.certname.to_s, n.environment.to_s, n.collector.to_s, roles_of.fetch(n.certname, []).join(',')]
          end
          print_table(COLUMNS, rows)
          exit 0
        rescue ::Driftless::ScanError => e
          fatal!("list nodes: #{e.message}")
        end

        protected

        def configure_parser(o)
          o.on('-i', '--incoming-dir=DIR',
               'Ingest dir holding all-active-nodes/',
               'Default: reports.incoming_dir from driftless.yaml') { |v| @options[:incoming_dir] = v }

          declare_node_selection(o)

          o.separator ''
          o.separator 'Environment scoping:'
          o.on('--environments=ENVS', Array,
               'List only nodes in these Puppet environment(s), comma-separated',
               'Default: puppet.environments from driftless.yaml; unset lists every node') do |v|
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
          fatal!('list nodes: --incoming-dir required (or set reports.incoming_dir in driftless.yaml)', help: true)
        end

        def config_defaults
          cfg = ::Driftless.config
          {
            incoming_dir:       cfg.dig('reports', 'incoming_dir'),
            environments:       cfg.dig('puppet',  'environments'),
            proceed_with_subset_of_configured_envs: cfg.dig('puppet', 'proceed_with_subset_of_configured_envs'),
          }.compact
        end

        # Roles per certname for the roles column; empty when the classes
        # report is not loaded.
        def roles_by_certname(reported)
          return {} if reported.missing?(::Driftless::NodeSelector::CLASSES_REPORT)
          reported.report(::Driftless::NodeSelector::CLASSES_REPORT).to_h do |node|
            [node.certname, ::Driftless::Utilization.names(node, 'roles')]
          end
        end
      end
    end
  end
end
