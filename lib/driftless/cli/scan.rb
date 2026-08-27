require 'driftless/cli/base'
require 'driftless/cli/root'
require 'driftless/cli/import'
require 'driftless/config_keys'
require 'driftless/scan'
require 'driftless/fail_on'
require 'driftless/control_repo'
require 'driftless/outputs'
require 'driftless/ansi'
require 'driftless/scan_data'

module Driftless
  module CLI
    class Scan < Base
      extend ::Driftless::ConfigKeys::DSL

      register_command name: 'scan', subcommand_of: Root

      config_key 'scan.fail_on', type: :string, default: 'any',
                 about: 'Exit non-zero on findings: any, none, or comma-joined severity/quality terms'
      config_key 'detectors.only', type: :array, default: nil,
                 about: 'Run only these detector keys'
      config_key 'detectors.skip', type: :array, default: nil,
                 about: 'Skip these detector keys'
      desc 'Cross-reference control repo against PuppetDB reports'

      def execute(argv)
        reject_extra_args!(argv)
        begin
          fail_on = ::Driftless::FailOn.parse(@options[:fail_on])
        rescue ArgumentError => e
          fatal!(e.message, help: true)
        end

        repo = if @options[:repo_dir]
                 ::Driftless::ControlRepo.new(@options[:repo_dir])
               else
                 ::Driftless::ControlRepo.detect(Dir.pwd)
               end
        @options[:repo_dir]       = repo&.dir
        @options[:incoming_dir] ||= repo&.default_incoming_dir
        @options[:incoming_dir]   = File.expand_path(@options[:incoming_dir]) if @options[:incoming_dir]

        unless @options[:repo_dir] && @options[:incoming_dir]
          missing = []
          missing << '--repo-dir'     unless @options[:repo_dir]
          missing << '--incoming-dir' unless @options[:incoming_dir]
          pronoun = (missing.length > 1) ? 'them' : 'it'
          fatal!("scan requires #{missing.join(' and ')} (auto-detection did not supply #{pronoun})", help: true)
        end

        unless repo.readable?
          fatal!("repo-dir not readable: #{repo.dir}", 3)
        end

        unless File.directory?(@options[:incoming_dir])
          fatal!("incoming-dir not readable: #{@options[:incoming_dir]}", 3)
        end

        unless @options[:environments]&.any?
          fatal!('scan error: puppet.environments is required — set it in driftless.yaml or pass --environments', help: true)
        end

        summary_dir =
          if @options[:summary_dir]
            File.expand_path(@options[:summary_dir])
          else
            File.join(File.dirname(@options[:incoming_dir]), 'summary')
          end

        begin
          scanner = ::Driftless::Scan.new(
            repo_dir:                       @options[:repo_dir],
            incoming_dir:                   @options[:incoming_dir],
            only:                           @options[:only],
            skip:                           @options[:skip],
            basemodulepath:                 @options[:basemodulepath],
            environments:                   @options[:environments],
            allow_missing_envs:             @options[:allow_missing_envs] || false,
            accept_duplicate_certnames:     @options[:accept_duplicate_certnames] || false,
            summary_dir:                    summary_dir,
            accept_partial_report_sessions: @options[:accept_partial_report_sessions],
          )
          findings = scanner.run
        rescue ::Driftless::ScanError => e
          fatal!("scan error: #{e.message}")
        end

        emit(findings, warnings: scanner.warnings)
        write_data_file(scanner, findings) if @options[:data_file]

        exit(fail_on.fail?(findings) ? 1 : 0)
      end

      protected

      def option_defaults
        { fail_on: 'any', tabularize: true }
      end

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
        o.on('-f', '--format=FMT', ::Driftless::Outputs.formats,
             "Output format: #{::Driftless::Outputs.formats.join(' or ')} " \
             '(default: text on TTY, json otherwise)') { |v| @options[:format] = v }
        o.on('-o', '--output-file=PATH',
             'Write output to this file instead of stdout') do |v|
          @options[:output_file] = v
          implied = ::Driftless::Outputs.format_for_filename(v)
          @options[:format] = implied if implied
        end
        o.on('--[no-]tabularize',
             'Align finding messages in a column (default: on)') { |v| @options[:tabularize] = v }
        o.on('--data-file[=PATH]',
             'Also write the scan data document for `driftless site`',
             "(default PATH: #{::Driftless::ScanData::DEFAULT_PATH})") do |v|
          @options[:data_file] = v || ::Driftless::ScanData::DEFAULT_PATH
        end

        o.separator ''
        o.separator 'Environment scoping:'
        o.on('--environments=ENVS', Array,
             'Puppet environment(s) to lint, comma-separated (required)') do |v|
          @options[:environments] = v
        end
        o.on('--accept-duplicate-certnames',
             'Warn instead of erroring when one certname is reported by two collectors') do
          @options[:accept_duplicate_certnames] = true
        end
        o.on('--allow-missing-envs',
             'Warn instead of error when a listed environment has no reports') do
          @options[:allow_missing_envs] = true
        end

        o.separator ''
        o.separator 'Other:'
        o.on('--basemodulepath=PATH', 'Override $basemodulepath (colon-separated)') { |v| @options[:basemodulepath] = v.split(':') }
        o.on('--fail-on=TERMS',
             'Exit non-zero on findings: any (default), none, or',
             'comma-joined terms — a severity fails on itself or worse,',
             'a quality on exact match (e.g. error,stale)') { |v| @options[:fail_on] = v }
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
          tabularize:         cfg.dig('output',    'tabularize'),
          environments:       cfg.dig('puppet',    'environments'),
          allow_missing_envs: cfg.dig('puppet',    'allow_missing_envs'),
          accept_duplicate_certnames: cfg.dig('reports', 'accept_duplicate_certnames'),
          only:               cfg.dig('detectors', 'only'),
          skip:               cfg.dig('detectors', 'skip'),
          incoming_dir:       cfg.dig('reports',   'incoming_dir'),
        }.compact
      end

      # The scan data document is scan's output for `driftless site`: what the
      # terminal writers cannot carry (sessions, nodes, overrides, warnings,
      # revision), assembled from the finished scan (design notes §7).
      def write_data_file(scanner, findings)
        data = ::Driftless::ScanData.assemble(
          findings:     findings,
          corpus:       scanner.corpus,
          warnings:     scanner.warnings,
          environments: @options[:environments],
          overrides:    ::Driftless::ScanData.overrides_from(scanner),
        )
        path = ::Driftless::ScanData.write(data, File.expand_path(@options[:data_file]))
        ::Driftless.logger.info("scan data written: #{path}")
      end

      # The default format follows $stdout even when -o redirects to a file, so
      # that `-o findings.txt` from a terminal still renders as text.
      #
      # Warnings replay through the logger between the findings list and the
      # count table, so on a TTY they sit beside the totals instead of
      # scrolled away above the findings.
      def emit(findings, warnings: [])
        format = @options[:format] || ::Driftless::Outputs.default_format($stdout)
        out    = @options[:output_file] ? File.open(@options[:output_file], 'w') : $stdout
        color  = ::Driftless::Ansi.enabled?(out)
        ::Driftless::Outputs.write(findings, out, format: format,
                                   color: color, tabularize: @options[:tabularize])
        # Piped stdout is block-buffered while stderr is not; without the flush
        # the replayed warnings land above the findings in a merged stream.
        out.flush
        warnings.each { |w| ::Driftless.logger.warn(w) }
        ::Driftless::Outputs.write_summary(findings, out, format: format, color: color)
      ensure
        out.close if out && out != $stdout
      end
    end
  end
end
