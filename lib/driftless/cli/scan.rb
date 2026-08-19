require 'driftless/cli/base'
require 'driftless/cli/root'
require 'driftless/cli/import'
require 'driftless/scan'
require 'driftless/outputs/json_writer'
require 'driftless/outputs/text_writer'

module Driftless
  module CLI
    class Scan < Base
      register_command name: 'scan', subcommand_of: Root
      desc 'Cross-reference control repo against PuppetDB reports'

      class << self
        def default_repo_dir(cwd)
          return cwd if File.exist?(File.join(cwd, 'hiera.yaml')) &&
                        File.exist?(File.join(cwd, 'environment.conf'))
          nil
        end

        def default_incoming_dir(repo_dir)
          return nil unless repo_dir
          candidate = File.join(repo_dir, 'incoming')
          File.directory?(candidate) ? candidate : nil
        end
      end

      def initialize(parent_options: {})
        super
        # Precedence (highest → lowest, in @options):
        #   1. CLI flags (parsed later, overwrite everything)
        #   2. parent_options (inherited from Root's own CLI flags — verbose, etc.)
        #   3. config-derived values (from driftless.yaml, mapped via config_defaults)
        #   4. hardcoded defaults (fail_on: 'any')
        @options = { fail_on: 'any' }.merge(config_defaults).merge(@options)
      end

      def execute(_argv)
        @options[:repo_dir]     ||= self.class.default_repo_dir(Dir.pwd)
        # Normalize path to absolute before auto-detecting incoming_dir
        # to be consistent with `-d .`
        @options[:repo_dir]       = File.expand_path(@options[:repo_dir]) if @options[:repo_dir]
        @options[:incoming_dir] ||= self.class.default_incoming_dir(@options[:repo_dir])
        @options[:incoming_dir]   = File.expand_path(@options[:incoming_dir]) if @options[:incoming_dir]

        unless @options[:repo_dir] && @options[:incoming_dir]
          missing = []
          missing << '--repo-dir'     unless @options[:repo_dir]
          missing << '--incoming-dir' unless @options[:incoming_dir]
          pronoun = (missing.length > 1) ? 'them' : 'it'
          warn "scan requires #{missing.join(' and ')} (auto-detection did not supply #{pronoun})"
          print_help($stderr)
          exit 2
        end

        unless File.directory?(@options[:repo_dir])
          warn "repo-dir not readable: #{@options[:repo_dir]}"
          exit 3
        end

        unless File.directory?(@options[:incoming_dir])
          warn "incoming-dir not readable: #{@options[:incoming_dir]}"
          exit 3
        end

        unless @options[:environments]&.any?
          warn 'scan error: puppet.environments is required — set it in driftless.yaml or pass --environments'
          print_help($stderr)
          exit 2
        end

        summary_dir =
          if @options[:summary_dir]
            File.expand_path(@options[:summary_dir])
          else
            File.join(File.dirname(@options[:incoming_dir]), 'summary')
          end

        begin
          findings = ::Driftless::Scan.new(
            repo_dir:                       @options[:repo_dir],
            incoming_dir:                   @options[:incoming_dir],
            only:                           @options[:only],
            skip:                           @options[:skip],
            basemodulepath:                 @options[:basemodulepath],
            environments:                   @options[:environments],
            allow_missing_envs:             @options[:allow_missing_envs] || false,
            summary_dir:                    summary_dir,
            accept_partial_report_sessions: @options[:accept_partial_report_sessions],
          ).run
        rescue ::Driftless::ScanError => e
          warn "scan error: #{e.message}"
          exit 2
        end

        emit(findings)

        exit 0 if @options[:fail_on] == 'never'
        exit(findings.empty? ? 0 : 1)
      end

      protected

      def configure_parser(o)
        o.separator ''
        o.separator 'Required (auto-detected when omitted):'
        o.on('-d', '--repo-dir=DIR',
             'Path to the control repo environment',
             "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        o.on('-i', '--incoming-dir=DIR',
             'Path to the incoming PuppetDB reports directory tree',
             "Default: 'incoming/' (if it exists)") { |v| @options[:incoming_dir] = v }
        o.on('-s', '--summary-dir=DIR',
             'Path to the summary/ tree written by `driftless import`',
             'Default: sibling summary/ of --incoming-dir') { |v| @options[:summary_dir] = v }

        o.separator ''
        o.separator 'Filtering:'
        o.on('--only=KEYS', Array, 'Run only these detector keys (comma-sep)') { |v| @options[:only] = v }
        o.on('--skip=KEYS', Array, 'Skip these detector keys (comma-sep)')     { |v| @options[:skip] = v }

        o.separator ''
        o.separator 'Output:'
        o.on('-f', '--format=FMT', %w[json text],
             'Output format: json or text (default: text on TTY, json otherwise)') { |v| @options[:format] = v }
        o.on('-o', '--output-file=PATH',
             'Write output to this file instead of stdout') do |v|
          @options[:output_file] = v
          @options[:format] = 'json' if v =~ /\.json\Z/i
        end

        o.separator ''
        o.separator 'Environment scoping:'
        o.on('--environments=ENVS', Array,
             'Puppet environments to lint, comma-separated (required)') do |v|
          @options[:environments] = v
        end
        o.on('--allow-missing-envs',
             'Warn instead of error when a listed environment has no reports') do
          @options[:allow_missing_envs] = true
        end

        o.separator ''
        o.separator 'Other:'
        o.on('--basemodulepath=PATH', 'Override $basemodulepath (colon-separated)') { |v| @options[:basemodulepath] = v.split(':') }
        o.on('--fail-on=WHEN', %w[any never],
             'Exit non-zero on findings: any (default) or never') { |v| @options[:fail_on] = v }
        Import.declare_accept_partial(o, @options)
      end

      private

      # Extracts config-derived defaults for this scan.
      def config_defaults
        cfg = ::Driftless.config
        {
          fail_on:            cfg.dig('scan',      'fail_on'),
          format:             cfg.dig('output',    'format'),
          output_file:        cfg.dig('output',    'default_file'),
          environments:       cfg.dig('puppet',    'environments'),
          allow_missing_envs: cfg.dig('puppet',    'allow_missing_envs'),
          only:               cfg.dig('detectors', 'only'),
          skip:               cfg.dig('detectors', 'skip'),
          incoming_dir:       cfg.dig('scan',      'incoming_dir'),
        }.compact
      end

      def emit(findings)
        format = @options[:format] || ($stdout.tty? ? 'text' : 'json')
        out    = @options[:output_file] ? File.open(@options[:output_file], 'w') : $stdout
        case format
        when 'json' then Outputs::JsonWriter.write(findings, out)
        else             Outputs::TextWriter.write(findings, out, color: resolve_color(out))
        end
      ensure
        out.close if out && out != $stdout
      end

      # Explicit --color / --no-color wins over NO_COLOR env; both win over
      # the writer's auto-on-TTY default (returned as nil).
      def resolve_color(_io)
        return @options[:color] unless @options[:color].nil?
        return false if ENV.key?('NO_COLOR') && !ENV['NO_COLOR'].empty?
        nil
      end
    end
  end
end
