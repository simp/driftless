require 'logger'
require 'optparse'

require 'pupgrade/config'
require 'pupgrade/config_validator'
require 'pupgrade/logging'
require 'pupgrade/version'

module Pupgrade
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

        # Subcommands with this declaration run without loading pupgrade.yaml
        def skip_config_load
          @skip_config_load = true
        end

        # A command with this declaration runs its own `execute` when the
        # arguments do not start with one of its subcommands, instead of
        # requiring one: `pupgrade compile -d DIR` compiles, `pupgrade
        # compile diff A B` dispatches.
        def runs_without_subcommand
          @runs_without_subcommand = true
        end

        def runs_without_subcommand?
          @runs_without_subcommand ? true : false
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
        # A hidden command runs when named in full, and help does not list it.
        def register_command(name:, subcommand_of: nil, hidden: false)
          @names  = Array(name).flatten.map(&:to_s)
          @hidden = hidden
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

        def hidden?
          @hidden ? true : false
        end

        # Returns the child class matching name_str exactly, or as an unambiguous
        # prefix of a child that is not hidden. Returns nil for no match. Raises
        # AmbiguousSubcommand for a prefix that matches more than one child.
        def find_subcommand(name_str)
          table = (@subcommands ||= {})
          return table[name_str] if table.key?(name_str)

          matches = table.select { |k, klass| k.start_with?(name_str) && !klass.hidden? }.keys
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
      # A command with subcommands parses its own options up to the first
      # positional and dispatches on it. One that runs without a subcommand
      # looks at that positional: a subcommand's name dispatches, anything
      # else makes this a leaf run, and the rest of the arguments are parsed
      # as its own.
      def run(argv)
        argv = argv.dup
        leaf = self.class.subcommands.empty?
        parse_own_options!(argv, leaf: leaf)
        if !leaf && self.class.runs_without_subcommand? && !names_subcommand?(argv)
          leaf = true
          parse_own_options!(argv, leaf: true)
        end
        ::Pupgrade::Ansi.preference = @options[:color]
        return dispatch(argv) unless leaf

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
        ::Pupgrade.logger.fatal(message)
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

      # Declares `--[un]NAME`: one help line for `--NAME`, giving the block
      # true, and `--unNAME`, giving it false. OptionParser spells such a
      # pair `--[no-]NAME`; its switch is built, then listed under the
      # other spelling.
      def on_un(parser, name, *desc, &block)
        switch, short, long, negative, = parser.make_switch(["--[no-]#{name}", *desc], block)
        switch.long.replace(["--[un]#{name}"])
        parser.top.append(switch, short, long, negative, ["un#{name}"])
      end

      # Hardcoded fallbacks for this command, below anything the config sets.
      def option_defaults
        {}
      end

      # Values this command reads out of pupgrade.yaml.
      def config_defaults
        {}
      end

      private

      def build_parser
        OptionParser.new do |o|
          o.version = Pupgrade::VERSION
          o.banner = self.class.desc ? "#{usage_line}\n\n#{self.class.desc}" : usage_line
          add_subcommand_section(o)
          o.separator ''
          o.separator 'Options:'
          configure_parser(o)
          add_config_flags(o)
          o.on('-v', '--verbose', 'Increase vebosity: -v (info), -vv (debug), -vvv (tracc)') do
            @options[:verbosity] = @options.fetch(:verbosity, 0) + 1
            apply_log_level
          end
          o.on('-q', '--quiet', 'Only errors') do
            @options[:quiet] = true
            apply_log_level
          end
          o.on('--[no-]color',    'Colorize terminal output (default: auto — on when stdout is a TTY)') { |v| @options[:color] = v }
          o.on('--width=N', Integer, %q[Wrap tables to N columns (default: the terminal's width; 0 for no limit)]) { |v| @options[:width] = v }
          o.on('-h', '--help',    'Show this help') do
            puts o
            exit 0
          end
        end
      end

      def add_config_flags(o)
        o.on('-c', '--config=FILE', 'Override config with FILE') { |v| @options[:config_path] = v }
        o.on('--no-config', 'Skip all config files') { @options[:no_config] = true }
      end

      def load_config!
        ::Pupgrade.config = ::Pupgrade::Config.load(
          config_path: @options[:config_path],
          no_config:   @options[:no_config],
        )
        ::Pupgrade::ConfigValidator.new(::Pupgrade.config).validate!
        @options[:log_level] ||= ::Pupgrade.config.dig('logging', 'level')
        apply_log_level
        ::Pupgrade::Ansi.configured = ::Pupgrade.config.dig('output', 'color')
      rescue ::Pupgrade::ConfigLoadError, ::Pupgrade::ConfigValidationError => e
        fatal!("config error: #{e.message}")
      end

      # Lowest to highest: hardcoded defaults, config file, then whatever is
      # already in @options — inherited from the parent or set by this
      # command's own flags.
      def apply_config_defaults
        @options = option_defaults.merge(config_defaults).merge(@options)
      end

      # Precedence: -q, then -v/-vv/-vvv, then logging.level from the config
      # (@options[:log_level]), then notice. Called as each flag is parsed and
      # again once the config is loaded, so a flag counts wherever it sits.
      def apply_log_level
        ::Pupgrade.logger.level =
          if @options[:quiet] then :error
          else
            case @options.fetch(:verbosity, 0)
            when 0 then config_log_level
            when 1 then :info
            when 2 then :debug
            else        :trace
            end
          end
      end

      # The configured level when it names one, else notice.
      def config_log_level
        name = @options[:log_level].to_s.downcase.to_sym
        ::Driftless::Logging::Logger::NAMES.key?(name) ? name : :notice
      end

      def usage_line
        parts = ['Usage:', *self.class.command_path]
        parts << '[options]'
        unless self.class.subcommands.empty?
          parts << (self.class.runs_without_subcommand? ? '[<subcommand>]' : '<subcommand>')
        end
        parts.concat(self.class.positional)
        parts.join(' ')
      end

      def add_subcommand_section(o)
        subs = self.class.subcommands.reject(&:hidden?).sort_by(&:canonical_name)
        return if subs.empty?
        o.separator ''
        o.separator 'Subcommands:'
        width = subs.map { |c| c.canonical_name.length }.max
        subs.each { |c| o.separator "    #{c.canonical_name.ljust(width)}   #{c.desc.lines.first}" }
      end

      # @param leaf [Boolean] whether this command runs itself: every
      #   argument is then its own, else parsing stops at the subcommand
      def parse_own_options!(argv, leaf: self.class.subcommands.empty?)
        parser = build_parser
        leaf ? parser.parse!(argv) : parser.order!(argv)
      rescue OptionParser::ParseError => e
        fatal!(e.message, help: true)
      end

      # Whether the first argument names (or unambiguously abbreviates) a
      # subcommand; an ambiguous one counts, so dispatch can report it.
      def names_subcommand?(argv)
        first = argv.first
        return false if first.nil? || first.start_with?('-')

        !self.class.find_subcommand(first).nil?
      rescue AmbiguousSubcommand
        true
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
