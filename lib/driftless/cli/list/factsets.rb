require 'driftless/cli/base'
require 'driftless/cli/list'
require 'driftless/cli/node_selection'
require 'driftless/inputs/factsets_loader'
require 'driftless/scan_error'

module Driftless
  module CLI
    class List
      # `driftless list factsets`
      #
      # One row per reported factset, narrowed by the node-selection flags.
      class Factsets < Base
        include NodeSelection

        register_command name: 'factsets', subcommand_of: List
        desc 'List reported factsets by certname, environment, collector, OS, and roles'

        COLUMNS = %w[certname environment collector os roles].freeze

        def execute(_argv)
          require_incoming_dir!

          loader = ::Driftless::Inputs::FactsetsLoader.new(
            incoming_dir:       File.expand_path(@options[:incoming_dir]),
            environments:       @options[:environments],
            proceed_with_subset_of_configured_envs: @options[:proceed_with_subset_of_configured_envs] || false,
          )
          nodes    = loader.load
          selector = node_selector
          nodes    = selector.select(nodes, loader.reported) unless selector.empty?
          roles_of = roles_by_certname(loader.reported)

          rows = nodes.sort_by { |n| n.certname.to_s }.map { |n| row(n, roles_of) }
          print_table(rows)
          exit 0
        rescue ::Driftless::ScanError => e
          fatal!("list factsets: #{e.message}")
        end

        protected

        def configure_parser(o)
          o.on('-i', '--incoming-dir=DIR',
               'Ingest dir holding factsets-for-all-active-nodes/',
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
          fatal!('list factsets: --incoming-dir required (or set reports.incoming_dir in driftless.yaml)', help: true)
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

        def row(node, roles_of)
          [
            node.certname.to_s,
            node.environment.to_s,
            node.collector.to_s,
            node.fact('os.name').to_s,
            roles_of.fetch(node.certname, []).join(','),
          ]
        end

        def print_table(rows)
          if rows.empty?
            puts '(nothing matches)'
            return
          end
          widths = COLUMNS.each_index.map { |i| ([COLUMNS[i]] + rows.map { |r| r[i] }).map(&:length).max }
          puts align(COLUMNS, widths)
          puts widths.map { |w| '-' * w }.join('-+-')
          rows.each { |r| puts align(r, widths) }
        end

        def align(cells, widths)
          cells.each_with_index.map { |c, i| c.ljust(widths[i]) }.join(' | ').rstrip
        end
      end
    end
  end
end
