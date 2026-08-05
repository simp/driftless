require 'logger'

module Driftless
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
