module Pupgrade
  # Terminal styling: raw escape codes, no gem. Ported from driftless's
  # Ansi so pupgrade's terminal output owes it nothing; the preference and
  # the configured value are mirrored onto driftless's Ansi by the CLI, so
  # the driftless code pupgrade calls colors the same way.
  module Ansi
    CODES = {
      red:     "\e[0;31m",
      green:   "\e[0;32m",
      yellow:  "\e[0;33m",
      blue:    "\e[0;34m",
      magenta: "\e[0;35m",
      cyan:    "\e[0;36m",
      white:   "\e[0;37m",
      grey:    "\e[0;90m",
      on_red:  "\e[41m",
      bold:    "\e[1m",
      dim:     "\e[2m",
      reverse: "\e[7m",
      reset:   "\e[0m",
    }.freeze

    class << self
      # --[no-]color and output.color: true, false, or nil for unset.
      attr_accessor :preference, :configured

      # Whether to colorize output bound for io. The flag is the most local
      # act, so it wins outright. NO_COLOR comes next: a config file
      # committed to a repo must not force color on someone who opted out
      # globally.
      def enabled?(io)
        return preference unless preference.nil?
        return false unless ENV['NO_COLOR'].to_s.empty?
        return configured unless configured.nil?

        io.respond_to?(:tty?) && io.tty?
      end

      # Codes beginning with a reset (`\e[0;...`) clear everything set
      # before them, so they are emitted first: `on_red, :white` would
      # otherwise render as plain white.
      def wrap(str, *styles)
        return str.to_s if styles.empty?

        codes = styles.map { |s| CODES.fetch(s) }
        resetting, additive = codes.partition { |c| c.start_with?("\e[0;") }
        "#{resetting.join}#{additive.join}#{str}#{CODES[:reset]}"
      end

      # The text in reverse video when the log's stream takes color: for a
      # line that must be seen among a flood of warnings.
      def stressed(str, io = $stderr)
        enabled?(io) ? wrap(str, :reverse) : str.to_s
      end
    end
  end
end
