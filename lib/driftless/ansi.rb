module Driftless
  # ANSI text styling helpers.
  #
  # Codes only — enablement is the caller's job. TextWriter gates on
  # io.tty? plus --[no-]color / NO_COLOR; nothing here mutates global state.
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
      bold:    "\e[1m",
      dim:     "\e[2m",
      reset:   "\e[0m",
    }.freeze

    def self.wrap(str, *styles)
      return str.to_s if styles.empty?
      prefix = styles.map { |s| CODES.fetch(s) }.join
      "#{prefix}#{str}#{CODES[:reset]}"
    end
  end
end
