require 'driftless/cli/base'
require 'driftless/cli/export'
require 'driftless/export/factsets'

module Driftless
  module CLI
    class Export
      class Factsets < Base
        register_command name: 'factsets', subcommand_of: Export
        desc 'Export reported factsets for onceover or puppet-lookup'

        def initialize(parent_options: {})
          super
          @options = { certname_globs: [] }.merge(config_defaults).merge(@options)
        end

        def execute(_argv)
          parse_format!
          require_output_dir!
          require_incoming_dir!

          result = ::Driftless::Export::Factsets.new(
            incoming_dir:   File.expand_path(@options[:incoming_dir]),
            output_dir:     File.expand_path(@options[:output_dir]),
            profile:        @options[:profile],
            serialization:  @options[:serialization],
            certname_globs: @options[:certname_globs],
            limit:          @options[:limit],
          ).run

          extra = result.skipped_no_certname.zero? ? '' : " (#{result.skipped_no_certname} skipped, no certname)"
          Driftless.logger.info(
            "export factsets: wrote #{result.written} file(s) to " \
            "#{@options[:output_dir]} [#{@options[:profile]}:#{@options[:serialization]}]#{extra}",
          )
          exit 0
        rescue ::Driftless::Export::Error => e
          warn "export factsets: #{e.message}"
          exit 2
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
               'Default: scan.incoming_dir from driftless.yaml') { |v| @options[:incoming_dir] = v }
          o.on('--certname=GLOB',
               'Export only certnames matching GLOB (repeatable; File.fnmatch syntax)') do |v|
            @options[:certname_globs] << v
          end
          o.on('--limit=N', Integer, 'Cap emitted files (after filter, sorted by certname)') { |v| @options[:limit] = v }
        end

        private

        def parse_format!
          fmt = @options[:format] || 'onceover'
          profile, serialization = fmt.split(':', 2)
          unless ::Driftless::Export::Factsets::PROFILES.key?(profile)
            known = ::Driftless::Export::Factsets::PROFILES.keys.join(', ')
            warn "export factsets: unknown --format profile #{profile.inspect} (known: #{known})"
            exit 2
          end
          if serialization && !::Driftless::Export::Factsets::SERIALIZATIONS.include?(serialization)
            known = ::Driftless::Export::Factsets::SERIALIZATIONS.join(', ')
            warn "export factsets: unknown --format serialization #{serialization.inspect} (known: #{known})"
            exit 2
          end
          @options[:profile]       = profile
          @options[:serialization] = serialization ||
            ::Driftless::Export::Factsets::PROFILES.fetch(profile)[:default_serialization]
        end

        def require_output_dir!
          return if @options[:output_dir]
          warn 'export factsets: --output-dir required'
          print_help($stderr)
          exit 2
        end

        def require_incoming_dir!
          return if @options[:incoming_dir]
          warn 'export factsets: --incoming-dir required (or set scan.incoming_dir in driftless.yaml)'
          print_help($stderr)
          exit 2
        end

        def profile_default(name)
          ::Driftless::Export::Factsets::PROFILES.fetch(name)[:default_serialization]
        end

        def config_defaults
          cfg = ::Driftless.config
          { incoming_dir: cfg.dig('scan', 'incoming_dir') }.compact
        end
      end
    end
  end
end
