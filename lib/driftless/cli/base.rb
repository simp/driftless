require 'logger'
require 'optparse'

require 'driftless/config'
require 'driftless/config_validator'
require 'driftless/logger'

module Driftless
  module CLI
    class Base
      # Raised by find_subcommand when a prefix matches more than one subcommand.
      class AmbiguousSubcommand < StandardError
        attr_reader :input, :candidates

        def initialize(input, candidates)
          @input      = input
          @candidates = candidates
          super("ambiguous subcommand '#{input}' — matches: #{candidates.join(', ')}")
        end
      end

      class << self
        # ---- DSL ----------------------------------------------------------

        def desc(text = nil)
          text.nil? ? @desc : (@desc = text)
        end

        # Positional-arg tokens for this subcommand
        # Appended to the `Usage:` line after `[options]`
        def positional(*tokens)
          tokens.empty? ? (@positional || []) : (@positional = tokens.map(&:to_s))
        end

        # Subcommands with this declaration run without loading driftless.yaml
        def skip_config_load
          @skip_config_load = true
        end

        def skip_config_load?
          @skip_config_load ? true : false
        end

        # Getter for the command's names (canonical + aliases). Set via register_command.
        def name
          @names || []
        end

        def canonical_name
          name.first
        end

        # Atomic registration — declare this class as a command with these names,
        # optionally as a child of a parent command class. Both pieces arrive
        # together, so there is no order-of-DSL question to reason about.
        def register_command(name:, subcommand_of: nil)
          @names = Array(name).flatten.map(&:to_s)
          return if subcommand_of.nil?
          @parent_command = subcommand_of
          subcommand_of.add_subcommand(self)
        end

        # ---- Registry -----------------------------------------------------

        # Called by a child during register_command to slot itself into a parent's
        # subcommands table. Not typically called directly.
        def add_subcommand(klass)
          @subcommands ||= {}
          klass.name.each do |n|
            existing = @subcommands[n]
            if existing && existing != klass
              raise "subcommand name collision on #{self}: '#{n}' claimed by both " \
                    "#{existing} and #{klass}"
            end
            @subcommands[n] = klass
          end
        end

        def subcommands
          (@subcommands ||= {}).values.uniq
        end

        # Returns the child class matching name_str exactly, or as an unambiguous
        # prefix. Returns nil for no match. Raises AmbiguousSubcommand for a prefix
        # that matches more than one child.
        def find_subcommand(name_str)
          table = (@subcommands ||= {})
          return table[name_str] if table.key?(name_str)

          matches = table.keys.select { |k| k.start_with?(name_str) }
          case matches.size
          when 0 then nil
          when 1 then table[matches.first]
          else        raise AmbiguousSubcommand.new(name_str, matches.sort)
          end
        end

        # ---- Command tree walking ----------------------------------------

        attr_reader :parent_command

        def command_path
          (parent_command ? parent_command.command_path : []) + [canonical_name]
        end

        # ---- Entry point -------------------------------------------------

        def run(argv)
          new.run(argv)
        end
      end

      # ---- Instance API --------------------------------------------------

      # parent_options is a snapshot at construction time — the child dups it,
      # then its own parse writes to @options. Child mutations don't bubble up.
      def initialize(parent_options: {})
        @options = parent_options.dup
      end

      # Parses this command's own options, then dispatches to a subcommand or
      # executes. The color preference is set at every level, so a fatal raised
      # while dispatching honours --[no-]color.
      def run(argv)
        argv = argv.dup
        parse_own_options!(argv)
        ::Driftless::Ansi.preference = @options[:color]
        return dispatch(argv) unless self.class.subcommands.empty?

        after_own_parse
        apply_log_level
        execute(argv)
      end

      # Loads config file, then layers its values under whatever the command
      # line already set.
      def after_own_parse
        load_config! unless self.class.skip_config_load?
        apply_config_defaults
      end

      def print_help(io = $stdout)
        io.puts build_parser
      end

      # Leaves override to do work.
      def execute(_argv)
        raise NotImplementedError, "#{self.class} must implement #execute"
      end

      protected

      # Report a condition the command cannot continue past, and stop.
      # message names the command, since the severity label does not.
      def fatal!(message, exit_code = 2, help: false)
        ::Driftless.logger.fatal(message)
        print_help($stderr) if help
        exit exit_code
      end

      # Stop on positionals beyond the `max` the command declares. A stray
      # one is usually an optional argument given detached (`--data-file
      # out.json` reads as the default path plus a positional).
      def reject_extra_args!(argv, max: 0)
        extra = argv.drop(max)
        return if extra.empty?

        fatal!("#{self.class.canonical_name}: unexpected argument#{'s' if extra.size > 1} " \
               "#{extra.map(&:inspect).join(' ')}", help: true)
      end

      # Subclasses override to add their own options to the parser.
      def configure_parser(_parser); end

      # Hardcoded fallbacks for this command, below anything the config sets.
      def option_defaults
        {}
      end

      # Values this command reads out of driftless.yaml.
      def config_defaults
        {}
      end

      private

      def build_parser
        OptionParser.new do |o|
          o.banner = usage_line
          add_subcommand_section(o)
          o.separator ''
          o.separator 'Options:'
          configure_parser(o)
          add_config_flags(o)
          o.on('-v', '--verbose', 'Verbose output (repeat for debug: -vv)') do
            if @options[:verbose]
              @options[:debug] = true
            else
              @options[:verbose] = true
            end
          end
          o.on('-q', '--quiet',   'Suppress non-error output') { @options[:quiet] = true }
          o.on('--[no-]color',    'Colorize terminal output (default: auto — on when stdout is a TTY)') { |v| @options[:color] = v }
          o.on('-h', '--help',    'Show this help') do
            puts o
            exit 0
          end
        end
      end

      # Left undeclared, OptionParser completes a bare -c to --color and
      # silently discards the path.
      def add_config_flags(o)
        o.on('-c', '--config=PATH',
             'Use only PATH as the config file (replaces the search chain)') do |v|
          @options[:config_path] = v
        end
        o.on('--no-config',
             'Skip all config files (ignore system, user, and project driftless.yaml)') do
          @options[:no_config] = true
        end
      end

      def load_config!
        ::Driftless.config = ::Driftless::Config.load(
          config_path: @options[:config_path],
          no_config:   @options[:no_config],
        )
        # Validation needs all detector classes loaded (so their config_options
        # are declared). lib/driftless.rb requires each detector at load time.
        require 'driftless'
        ::Driftless::ConfigValidator.new(::Driftless.config).validate!
        @options[:log_level] ||= ::Driftless.config.dig('logging', 'level')
        ::Driftless::Ansi.configured = ::Driftless.config.dig('output', 'color')
      rescue ::Driftless::ConfigLoadError, ::Driftless::ConfigValidationError => e
        fatal!("config error: #{e.message}")
      end

      # Lowest to highest: hardcoded defaults, config file, then whatever is
      # already in @options — inherited from the parent or set by this
      # command's own flags.
      def apply_config_defaults
        @options = option_defaults.merge(config_defaults).merge(@options)
      end

      # Precedence: CLI flags (verbose/debug/quiet) win, then config-derived
      # @options[:log_level] (populated by Root from logging.level), then default WARN.
      # rubocop:disable Lint/UselessConstantScoping -- public access intended
      LOG_LEVEL_NAMES = {
        'debug' => Logger::DEBUG,
        'info'  => Logger::INFO,
        'warn'  => Logger::WARN,
        'error' => Logger::ERROR,
        'fatal' => Logger::FATAL,
      }.freeze
      # rubocop:enable Lint/UselessConstantScoping

      def apply_log_level
        ::Driftless.logger.level =
          if    @options[:quiet]   then Logger::ERROR
          elsif @options[:debug]   then Logger::DEBUG
          elsif @options[:verbose] then Logger::INFO
          elsif @options[:log_level]
            LOG_LEVEL_NAMES.fetch(@options[:log_level].to_s.downcase, Logger::WARN)
          else
            Logger::WARN
          end
      end

      def usage_line
        parts = ['Usage:', *self.class.command_path]
        parts << '[options]'
        parts << '<subcommand>' unless self.class.subcommands.empty?
        parts.concat(self.class.positional)
        parts.join(' ')
      end

      def add_subcommand_section(o)
        subs = self.class.subcommands
        return if subs.empty?
        o.separator ''
        o.separator 'Subcommands:'
        width = subs.map { |c| c.canonical_name.length }.max
        subs.each { |c| o.separator "    #{c.canonical_name.ljust(width)}   #{c.desc}" }
      end

      def parse_own_options!(argv)
        parser = build_parser
        if self.class.subcommands.empty?
          parser.parse!(argv)
        else
          parser.order!(argv)
        end
      rescue OptionParser::ParseError => e
        fatal!(e.message, help: true)
      end

      def dispatch(argv)
        sub_name = argv.shift
        if sub_name.nil?
          print_help($stderr)
          exit 2
        end

        child =
          begin
            self.class.find_subcommand(sub_name)
          rescue AmbiguousSubcommand => e
            fatal!(e.message, help: true)
          end

        unless child
          fatal!("unknown subcommand: #{sub_name}", help: true)
        end

        child.new(parent_options: @options).run(argv)
      end
    end
  end
end
