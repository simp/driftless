require 'driftless/version'
require 'driftless/config'
require 'driftless/config_validator'
require 'driftless/cli/base'
require 'driftless/detectors'

module Driftless
  module CLI
    class Root < Base
      register_command name: 'driftless'
      desc 'Puppet/OpenVox control-repo linter'

      # After Root parses its own options (in particular --config / --no-config),
      # load the process-wide config from disk AND validate it strictly against
      # the registered detectors and known subsystems. Any load or validation
      # error surfaces as a clean user-facing message on stderr; exit 2 (same
      # status as other usage errors).
      def after_own_parse
        ::Driftless.config = ::Driftless::Config.load(
          config_path: @options[:config_path],
          no_config:   @options[:no_config],
        )
        # Validation needs all detector classes loaded (so their config_options
        # are declared). lib/driftless.rb requires each detector at load time.
        require 'driftless'
        ::Driftless::ConfigValidator.new(::Driftless.config).validate!

        # Populate cross-cutting @options keys from config. CLI flags parsed
        # BEFORE this hook already set :verbose/:debug/:quiet if present, so
        # they win over :log_level via apply_log_level's precedence chain.
        @options[:log_level] ||= ::Driftless.config.dig('logging', 'level')
      rescue ::Driftless::ConfigLoadError, ::Driftless::ConfigValidationError => e
        warn "config error: #{e.message}"
        exit 2
      end

      protected

      def configure_parser(o)
        o.on('-c', '--config=PATH', 'Use only PATH as the config file (replaces the search chain)') do |v|
          @options[:config_path] = v
        end
        o.on('--no-config', 'Skip all config files (ignore system, user, and project driftless.yaml)') do
          @options[:no_config] = true
        end
        o.on('--version', 'Print the driftless version') do
          puts Driftless::VERSION
          exit 0
        end
      end
    end
  end
end

# Load Root's siblings — each child registers itself via subcommand_of Root.
Dir[File.join(__dir__, '*.rb')].sort.each do |file|
  next if %w[base.rb root.rb].include?(File.basename(file))
  require file
end
