module Driftless
  # ANSI text styling helpers.
  #
  # Shape follows Puppet::Util::Colors (raw escape constants, no gem).
  module Ansi
    CODES = {
      red:     "\e[0;31m",
      green:   "\e[0;32m",
      yellow:  "\e[0;33m",
      blue:    "\e[0;34m",
      magenta: "\e[0;35m",
      cyan:    "\e[0;36m",
      white:   "\e[0;37m",
      on_red:  "\e[41m",
      bold:    "\e[1m",
      dim:     "\e[2m",
      reset:   "\e[0m",
    }.freeze

    class << self
      # What --color / --no-color asked for: true, false, or nil for auto.
      # Set once by the CLI; every stream's decision reads it.
      attr_accessor :preference

      # Whether to colorize output bound for io. An explicit --color/--no-color
      # wins over NO_COLOR, which wins over whether io is a terminal.
      def enabled?(io)
        return preference unless preference.nil?
        return false unless ENV['NO_COLOR'].to_s.empty?
        io.respond_to?(:tty?) && io.tty?
      end

      # Codes beginning with a reset (`\e[0;...`) clear everything set before
      # them, so they are emitted first: `on_red, :white` would otherwise
      # render as plain white.
      def wrap(str, *styles)
        return str.to_s if styles.empty?
        codes = styles.map { |s| CODES.fetch(s) }
        resetting, additive = codes.partition { |c| c.start_with?("\e[0;") }
        "#{resetting.join}#{additive.join}#{str}#{CODES[:reset]}"
      end
    end
  end
end
