require 'driftless/cli/base'
require 'driftless/cli/export'
require 'driftless/cli/node_selection'
require 'driftless/export/factsets'

module Driftless
  module CLI
    class Export
      class Factsets < Base
        include NodeSelection

        register_command name: 'factsets', subcommand_of: Export
        desc 'Export reported factsets for onceover or puppet-lookup'

        def execute(_argv)
          parse_format!
          require_output_dir!
          require_incoming_dir!

          result = ::Driftless::Export::Factsets.new(
            incoming_dir:       File.expand_path(@options[:incoming_dir]),
            output_dir:         File.expand_path(@options[:output_dir]),
            profile:            @options[:profile],
            serialization:      @options[:serialization],
            selector:           node_selector,
            limit:              @options[:limit],
            environments:       @options[:environments],
            allow_missing_envs: @options[:allow_missing_envs] || false,
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
          o.on('--limit=N', Integer, 'Cap emitted files (after selection, sorted by certname)') { |v| @options[:limit] = v }

          declare_node_selection(o)

          o.separator ''
          o.separator 'Environment scoping:'
          o.on('--environments=ENVS', Array,
               'Export only nodes in these Puppet environment(s), comma-separated',
               'Default: puppet.environments from driftless.yaml; unset exports every node') do |v|
            @options[:environments] = v
          end
          o.on('--allow-missing-envs',
               'Warn instead of error when a listed environment has no reports') do
            @options[:allow_missing_envs] = true
          end
        end

        private

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
            allow_missing_envs: cfg.dig('puppet',  'allow_missing_envs'),
          }.compact
        end
      end
    end
  end
end
