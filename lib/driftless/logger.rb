require 'logger'

require 'driftless/config_keys'

module Driftless
  # Namespace for the logging subsystem's config. Level is applied by the CLI,
  # which lets -v / -vv / -q override it.
  module Logging
    extend ConfigKeys::DSL

    config_key 'logging.level', type: :string, default: 'warn',
               about: 'debug, info, warn, error, or fatal'
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
        l.formatter = proc { |sev, _time, _prog, msg| "#{sev.downcase}: #{msg}\n" }
      end
    end
  end
end
