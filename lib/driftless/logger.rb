require 'logger'

require 'driftless/ansi'
require 'driftless/config_keys'

module Driftless
  # Namespace for the logging subsystem's config. Level is applied by the CLI,
  # which lets -v / -vv / -q override it.
  module Logging
    extend ConfigKeys::DSL

    config_key 'logging.level', type: :string, default: 'warn',
               about: 'debug, info, warn, error, or fatal'

    # Styling for the severity label. Debug is absent: the whole line dims.
    SEVERITY_STYLES = {
      'fatal' => %i[on_red white bold],
      'error' => %i[red bold],
      'warn'  => %i[yellow],
    }.freeze

    # The formatter every Driftless logger uses. Public so a substituted
    # logger can keep the same output shape.
    def self.formatter
      proc { |severity, _time, _progname, message| format_line(severity, message) }
    end

    def self.format_line(severity, message)
      severity = severity.downcase
      label = (severity == 'fatal') ? 'FATAL' : severity
      return "#{label}: #{message}\n" unless Ansi.enabled?($stderr)
      return "#{Ansi.wrap("#{label}: #{message}", :dim)}\n" if severity == 'debug'

      styles = SEVERITY_STYLES[severity]
      styles ? "#{Ansi.wrap("#{label}:", *styles)} #{message}\n" : "#{label}: #{message}\n"
    end
  end

  class << self
    attr_writer :logger

    def logger
      @logger ||= build_default_logger
    end

    private

    def build_default_logger
      Logger.new($stderr).tap do |l|
        l.level     = Logger::WARN
        l.formatter = Logging.formatter
      end
    end
  end
end
