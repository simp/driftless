require 'fileutils'

require 'driftless/logger'
require 'driftless/ansi'

require 'pupgrade/ansi'
require 'pupgrade/config_keys'

module Pupgrade
  # pupgrade logs through driftless's logger, so the driftless library code
  # it calls and its own commands write one stream in one format. The level
  # is applied by the CLI, which lets -v / -vv / -vvv / -q override it.
  module Logging
    extend ConfigKeys::DSL

    config_key 'logging.level', type: :string, default: 'notice',
               about: 'trace (command output), debug (each decision and file), info (each item worked on), ' \
                      'notice (what the command did), warning, error, or fatal'
    config_key 'logging.file', type: :string, default: nil, example: 'pupgrade/logs/pupgrade.log',
               about: 'A file the log is written to as well, uncolored, under a header line naming the run; ' \
                      'relative to the current directory. --log-file overrides; catalog compile has its own default, compile.log_file'
    config_key 'logging.file_level', type: :string, default: 'debug',
               about: 'The level the file takes, apart from the terminal\'s: trace, debug, info, notice, warning, error, or fatal'
    config_key 'logging.file_mode', type: :string, default: 'overwrite',
               about: 'overwrite: the file holds the latest run, the runs before it kept as FILE.1, FILE.2, ... up to ' \
                      'logging.file_keep; append: every run in the file, each under its header'
    config_key 'logging.file_keep', type: :integer, default: 3,
               about: 'Under overwrite, how many earlier runs are kept beside the file (0: none)'

    FILE_MODES = %w[overwrite append].freeze

    # The terminal's logger with a file alongside. Every message goes to
    # the file at the file's own level, stripped of escape codes, then to
    # the terminal at its. The level, its name, and the `level?` and
    # `level!` methods are the terminal's; the file's level is fixed when
    # it is attached.
    class Tee
      ESCAPES = /\e\[[0-9;]*m/.freeze

      # @param terminal [Driftless::Logging::Logger]
      # @param file [Driftless::Logging::Logger] on the file, at its level
      def initialize(terminal, file)
        @terminal = terminal
        @file     = file
      end

      # @return [Driftless::Logging::Logger] the terminal's logger
      attr_reader :terminal

      # @return [Driftless::Logging::Logger] the file's logger
      attr_reader :file

      ::Driftless::Logging::Logger::LEVELS.each do |name, number|
        define_method(name) { |progname = nil, &block| add(number, nil, progname, &block) }
        define_method(:"#{name}?") { @terminal.send(:"#{name}?") }
        define_method(:"#{name}!") { @terminal.send(:"#{name}!") }
      end
      alias warn warning
      alias warn? warning?
      alias warn! warning!

      def add(severity, message = nil, progname = nil)
        severity ||= ::Driftless::Logging::Logger::FATAL
        message = block_given? ? yield : progname if message.nil?
        @file.add(severity, message)
        @terminal.add(severity, message)
      end

      def unknown(progname = nil, &block)
        add(::Driftless::Logging::Logger::FATAL, nil, progname, &block)
      end

      def level=(severity)
        @terminal.level = severity
      end

      def level
        @terminal.level
      end

      def level_name
        @terminal.level_name
      end

      def formatter=(formatter)
        @terminal.formatter = formatter
      end

      def formatter
        @terminal.formatter
      end
    end

    class << self
      # The file's lines: the label as the terminal's, the message with the
      # escape codes pupgrade's `stressed` and the terminal formatter put in
      # taken out.
      def file_formatter
        proc do |severity, _time, _progname, message|
          label = (severity == 'FATAL') ? 'FATAL' : severity.downcase
          "#{label}: #{message.to_s.gsub(Tee::ESCAPES, '')}\n"
        end
      end

      # Opens the file, writes the run's header line, and makes the file a
      # second destination of pupgrade's logger. Under `overwrite` the
      # file holds this run alone, the earlier runs moved to `.1`, `.2`,
      # … up to `keep`; under `append` the run follows the ones before.
      #
      # @param path [String] the file; its directories are created
      # @param level [String, Symbol] the file's level
      # @param command_line [Array<String>] the run's arguments, for the header
      # @param mode [String] one of {FILE_MODES}
      # @param keep [Integer] under overwrite, how many earlier runs to keep
      # @raise [SystemCallError] when the file cannot be opened
      # @raise [ArgumentError] when the level is not one, or the mode
      def attach_file(path, level:, command_line: [], mode: 'overwrite', keep: 3)
        raise ArgumentError, "logging.file_mode: #{mode.inspect} is not overwrite or append" unless FILE_MODES.include?(mode.to_s)

        FileUtils.mkdir_p(File.dirname(path))
        rotate(path, keep.to_i) if mode.to_s == 'overwrite'
        io = File.open(path, (mode.to_s == 'append') ? 'a' : 'w') # rubocop:disable Style/FileOpen -- open for the rest of the run
        io.sync = true
        file = ::Driftless::Logging::Logger.new(io, level: level)
        file.formatter = file_formatter
        io.puts "--- pupgrade #{command_line.join(' ')} at #{Time.now.strftime('%Y-%m-%d %H:%M:%S %z')} ---"
        Pupgrade.logger = Tee.new(Pupgrade.logger, file)
      end

      # Closes the file and makes the terminal's logger pupgrade's again;
      # nothing when no file is attached. Called when a run ends.
      def detach_file
        while Pupgrade.logger.is_a?(Tee)
          tee = Pupgrade.logger
          Pupgrade.logger = tee.terminal
          tee.file.close
        end
      end

      # Moves the file to `.1`, `.1` to `.2`, and so on, the one past
      # `keep` dropped; nothing with `keep` 0, when the file is overwritten.
      def rotate(path, keep)
        return unless keep.positive? && File.exist?(path)

        (keep - 1).downto(1) { |i| File.rename("#{path}.#{i}", "#{path}.#{i + 1}") if File.exist?("#{path}.#{i}") }
        File.rename(path, "#{path}.1")
      end
    end
  end

  # Terminal color: the `output.color` key; {Ansi} does the styling.
  module Output
    extend ConfigKeys::DSL

    config_key 'output.color', type: :boolean, default: nil, example: true,
               about: 'Colour terminal output: true, false, or unset for auto (on when stdout is a TTY). ' \
                      '--[no-]color overrides; NO_COLOR in the environment wins over this file'
  end

  class << self
    def logger
      ::Driftless.logger
    end

    def logger=(logger)
      ::Driftless.logger = logger
    end
  end
end
