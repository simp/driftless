require 'logger'

require 'driftless/ansi'
require 'driftless/config_keys'

module Driftless
  # Namespace for the logging subsystem's config. Level is applied by the CLI,
  # which lets -v / -vv / -vvv / -q override it.
  module Logging
    extend ConfigKeys::DSL

    config_key 'logging.level', type: :string, default: 'notice',
               about: 'trace (command output), debug (each decision and file), info (each item worked on), ' \
                      'notice (what the command did), warning, error, or fatal'

    # Styling for the severity label. Trace and debug are absent: the whole
    # line dims.
    SEVERITY_STYLES = {
      'fatal'   => %i[on_red white bold],
      'error'   => %i[red bold],
      'warning' => %i[yellow],
    }.freeze

    DIMMED = %w[trace debug].freeze

    # The formatter every Driftless logger uses. Public so a substituted
    # logger can keep the same output shape.
    def self.formatter
      proc { |severity, _time, _progname, message| format_line(severity, message) }
    end

    def self.format_line(severity, message)
      severity = severity.downcase
      label = (severity == 'fatal') ? 'FATAL' : severity
      return "#{label}: #{message}\n" unless Ansi.enabled?($stderr)
      return "#{Ansi.wrap("#{label}: #{message}", :dim)}\n" if DIMMED.include?(severity)

      styles = SEVERITY_STYLES[severity]
      styles ? "#{Ansi.wrap("#{label}:", *styles)} #{message}\n" : "#{label}: #{message}\n"
    end

    # A logger with Puppet's seven levels, notice the default: trace and
    # debug for the inner workings, info for each item a command works on,
    # notice for what it did, then warning, error, and fatal.
    #
    # Ruby's Logger names its five severities lexically in every level-aware
    # method, so each is overridden here rather than the constants. The
    # levels are contiguous from 0, so `add`'s comparison and the label
    # lookup work on the integers unchanged.
    class Logger < ::Logger
      LEVELS = { trace: 0, debug: 1, info: 2, notice: 3, warning: 4, error: 5, fatal: 6 }.freeze
      LABELS = %w[TRACE DEBUG INFO NOTICE WARNING ERROR FATAL].freeze
      # The names `level=` accepts; `warn` is Ruby's spelling of warning.
      NAMES = LEVELS.merge(warn: 4).freeze

      LEVELS.each do |name, number|
        const_set(name.to_s.upcase, number)
        define_method(name) { |progname = nil, &block| add(number, nil, progname, &block) }
        define_method(:"#{name}?") { level <= number }
        define_method(:"#{name}!") { self.level = number }
      end
      alias warn warning
      alias warn? warning?
      alias warn! warning!

      def initialize(logdev, *args, level: NOTICE, **kwargs)
        super
      end

      # @param severity [Integer, String, Symbol] a level number of this
      #   class, or a level name
      def level=(severity)
        @level =
          if severity.is_a?(Integer)
            raise ArgumentError, "invalid log level: #{severity}" unless (0..LEVELS.size - 1).cover?(severity)

            severity
          else
            NAMES.fetch(severity.to_s.downcase.to_sym) { raise ArgumentError, "invalid log level: #{severity}" }
          end
      end

      # @return [Symbol] the level's name
      def level_name
        LEVELS.key(level)
      end

      def add(severity, *args, &block)
        super(severity || FATAL, *args, &block)
      end

      def unknown(progname = nil, &block)
        add(FATAL, nil, progname, &block)
      end

      private

      def format_severity(severity)
        LABELS[severity] || 'FATAL'
      end
    end
  end

  class << self
    attr_writer :logger

    def logger
      @logger ||= build_default_logger
    end

    private

    def build_default_logger
      Logging::Logger.new($stderr).tap do |l|
        l.formatter = Logging.formatter
      end
    end
  end
end
