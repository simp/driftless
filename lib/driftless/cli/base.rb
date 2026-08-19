require 'logger'
require 'optparse'

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

        # Positional-arg tokens for this leaf, appended to the Usage: line
        # after `[options]`. Splat form so a leaf can declare several
        # (`positional '<src>', '[<dst>]'`) without concatenating strings.
        # Zero-arg call is the reader.
        def positional(*tokens)
          tokens.empty? ? (@positional || []) : (@positional = tokens.map(&:to_s))
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

        def parent_command
          @parent_command
        end

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

      def run(argv)
        argv = argv.dup
        parse_own_options!(argv)
        after_own_parse
        apply_log_level
        if self.class.subcommands.empty?
          execute(argv)
        else
          dispatch(argv)
        end
      end

      # Hook fired after this command's own options are parsed but before
      # the log-level derivation and dispatch/execute step. Default no-op;
      # {Root} overrides to load the process-wide config from disk.
      def after_own_parse; end

      def print_help(io = $stdout)
        io.puts build_parser
      end

      # Leaves override to do work.
      def execute(_argv)
        raise NotImplementedError, "#{self.class} must implement #execute"
      end

      protected

      # Subclasses override to add their own options to the parser.
      def configure_parser(_parser); end

      private

      def build_parser
        OptionParser.new do |o|
          o.banner = usage_line
          add_subcommand_section(o)
          o.separator ''
          o.separator 'Options:'
          configure_parser(o)
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

      # Precedence: CLI flags (verbose/debug/quiet) win, then config-derived
      # @options[:log_level] (populated by Root from logging.level), then default WARN.
      LOG_LEVEL_NAMES = {
        'debug' => Logger::DEBUG,
        'info'  => Logger::INFO,
        'warn'  => Logger::WARN,
        'error' => Logger::ERROR,
        'fatal' => Logger::FATAL,
      }.freeze

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
        warn e.message
        print_help($stderr)
        exit 2
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
            warn e.message
            print_help($stderr)
            exit 2
          end

        unless child
          warn "unknown subcommand: #{sub_name}"
          print_help($stderr)
          exit 2
        end

        child.new(parent_options: @options).run(argv)
      end
    end
  end
end
