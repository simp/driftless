require 'driftless/cli/base'
require 'driftless/cli/export'
require 'driftless/cli/node_selection'
require 'driftless/export/factsets'
require 'driftless/export/role_tree'

module Driftless
  module CLI
    class Export
      class Factsets < Base
        include NodeSelection

        register_command name: 'factsets', subcommand_of: Export
        desc 'Export reported factsets for onceover or puppet-lookup'

        DEFAULT_ROLE_TREE = 'spec/factsets/raw'.freeze

        def execute(_argv)
          require_incoming_dir!
          return execute_role_tree if @options[:role_tree]

          reject_role_tree_flags!
          parse_format!
          require_output_dir!

          result = ::Driftless::Export::Factsets.new(
            incoming_dir:       File.expand_path(@options[:incoming_dir]),
            output_dir:         File.expand_path(@options[:output_dir]),
            profile:            @options[:profile],
            serialization:      @options[:serialization],
            selector:           node_selector,
            limit:              @options[:limit],
            environments:       @options[:environments],
            proceed_with_subset_of_configured_envs: @options[:proceed_with_subset_of_configured_envs] || false,
          ).run

          extra = result.skipped_no_certname.zero? ? '' : " (#{result.skipped_no_certname} skipped, no certname)"
          Driftless.logger.info(
            "export factsets: wrote #{result.written} file(s) to " \
            "#{@options[:output_dir]} [#{@options[:profile]}:#{@options[:serialization]}]#{extra}",
          )
          exit 0
        rescue ::Driftless::Export::Error, ::Driftless::ScanError => e
          fatal!("export factsets: #{e.message}")
        end

        protected

        def option_defaults
          { pick: 'random' }
        end

        def configure_parser(o)
          o.on('-f', '--format=PROFILE[:SER]',
               'Consumer profile and serialization',
               "  onceover (default #{profile_default('onceover')})",
               "  lookup   (default #{profile_default('lookup')})",
               'Explicit override: onceover:yaml, lookup:json') { |v| @options[:format] = v }
          o.on('-o', '--output-dir=DIR', 'Target directory for exported factsets (required)') { |v| @options[:output_dir] = v }
          o.on('-i', '--incoming-dir=DIR',
               'Ingest dir holding factsets-for-all-active-nodes/',
               'Default: reports.incoming_dir from driftless.yaml') { |v| @options[:incoming_dir] = v }
          o.on('--limit=N', Integer,
               'Cap emitted files (after selection, sorted by certname);',
               'with --onceover-role-tree, factsets per role and collector (default 1)') { |v| @options[:limit] = v }

          o.separator ''
          o.separator 'Onceover role tree (implies --format onceover:json; not with --output-dir):'
          o.on('--onceover-role-tree[=DIR]',
               'Maintain DIR/<role::name>/<certname>.json, one factset per role and',
               "collector, refreshing files already there (default DIR: #{DEFAULT_ROLE_TREE})") do |v|
            @options[:role_tree] = v || DEFAULT_ROLE_TREE
          end
          o.on('--pick=HOW', ::Driftless::Export::RoleTree::PICKS,
               'How a collector\'s node is chosen for a role with none yet:',
               'random (default) or first (lowest certname)') { |v| @options[:pick] = v }
          o.on('--prune', 'Delete factsets whose node no longer reports with that role') { @options[:prune] = true }
          o.on('--ignore-stale-factsets', 'Warn about such factsets and proceed instead of stopping') do
            @options[:ignore_stale] = true
          end

          declare_node_selection(o)

          o.separator ''
          o.separator 'Environment scoping:'
          o.on('--environments=ENVS', Array,
               'Export only nodes in these Puppet environment(s), comma-separated',
               'Default: puppet.environments from driftless.yaml; unset exports every node') do |v|
            @options[:environments] = v
          end
          o.on('-b', '--proceed-with-subset-of-configured-envs',
               'Proceed with the reports for the environments present, even when they',
               'do not cover every environment in puppet.environments') do
            @options[:proceed_with_subset_of_configured_envs] = true
          end
        end

        private

        # @raise [SystemExit] on a flag the role tree does not take, via fatal!
        def execute_role_tree
          if @options[:output_dir]
            fatal!('export factsets: --onceover-role-tree writes under its own DIR; drop --output-dir', help: true)
          end
          if @options[:format] && !%w[onceover onceover:json].include?(@options[:format])
            fatal!("export factsets: --onceover-role-tree implies --format onceover:json, not #{@options[:format]}", help: true)
          end
          if @options[:prune] && @options[:ignore_stale]
            fatal!('export factsets: --prune and --ignore-stale-factsets are alternatives; pass one', help: true)
          end

          root   = File.expand_path(@options[:role_tree])
          result = ::Driftless::Export::RoleTree.new(
            incoming_dir: File.expand_path(@options[:incoming_dir]),
            root:         root,
            limit:        @options[:limit] || 1,
            pick:         @options[:pick],
            prune:        @options[:prune] || false,
            ignore_stale: @options[:ignore_stale] || false,
            selector:     node_selector,
            environments: @options[:environments],
            proceed_with_subset_of_configured_envs: @options[:proceed_with_subset_of_configured_envs] || false,
          ).run

          Driftless.logger.info(
            "export factsets: role tree #{root}: #{result.written} picked, #{result.updated} refreshed, " \
            "#{result.pruned} pruned, #{result.stale} stale",
          )
          exit 0
        rescue ::Driftless::Export::Error, ::Driftless::ScanError => e
          fatal!("export factsets: #{e.message}")
        end

        def reject_role_tree_flags!
          given = { '--pick' => @options[:pick] != 'random', '--prune' => @options[:prune],
                    '--ignore-stale-factsets' => @options[:ignore_stale] }.select { |_, v| v }.keys
          return if given.empty?
          fatal!("export factsets: #{given.join(', ')} only apply with --onceover-role-tree", help: true)
        end

        def parse_format!
          fmt = @options[:format] || 'onceover'
          profile, serialization = fmt.split(':', 2)
          unless ::Driftless::Export::Factsets::PROFILES.key?(profile)
            known = ::Driftless::Export::Factsets::PROFILES.keys.join(', ')
            fatal!("export factsets: unknown --format profile #{profile.inspect} (known: #{known})")
          end
          if serialization && !::Driftless::Export::Factsets::SERIALIZATIONS.include?(serialization)
            known = ::Driftless::Export::Factsets::SERIALIZATIONS.join(', ')
            fatal!("export factsets: unknown --format serialization #{serialization.inspect} (known: #{known})")
          end
          @options[:profile]       = profile
          @options[:serialization] = serialization || ::Driftless::Export::Factsets::PROFILES.fetch(profile)[:default_serialization]
        end

        def require_output_dir!
          return if @options[:output_dir]
          fatal!('export factsets: --output-dir required', help: true)
        end

        def require_incoming_dir!
          return if @options[:incoming_dir]
          fatal!('export factsets: --incoming-dir required (or set reports.incoming_dir in driftless.yaml)', help: true)
        end

        def profile_default(name)
          ::Driftless::Export::Factsets::PROFILES.fetch(name)[:default_serialization]
        end

        def config_defaults
          cfg = ::Driftless.config
          {
            incoming_dir:       cfg.dig('reports', 'incoming_dir'),
            environments:       cfg.dig('puppet',  'environments'),
            proceed_with_subset_of_configured_envs: cfg.dig('puppet', 'proceed_with_subset_of_configured_envs'),
          }.compact
        end
      end
    end
  end
end
