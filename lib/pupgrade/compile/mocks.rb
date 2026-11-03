require 'yaml'

require 'pupgrade/compile/enc'

module Pupgrade
  module Compile
    # What the execution guard answers with: the site's mock file, with
    # pupgrade's defaults for the probes package providers make when they
    # load, after it.
    #
    #     ---
    #     commands:
    #       - match: '\A/usr/bin/rpm --version\z'   # a regexp against the command line
    #         stdout: "RPM version 4.16.1.3\n"       # what it prints (default '')
    #         exit: 0                                # its exit code (default 0)
    #         when:                                  # only on nodes whose facts match
    #           os.family: [RedHat, Suse]
    #       - match: '^systemctl '
    #         action: allow                          # run it for real, and record it
    #     facts:                                     # merged over the factset's facts;
    #       fips_enabled: false                      #   ${facts.os.name} and the like resolve per node
    #     functions:                                 # Puppet functions answered without running
    #       - name: puppetdb_query
    #         returns: []
    #         when:
    #           os.family: RedHat
    #
    # The first entry whose `match` fits the command line and whose `when`
    # fits the node's facts is used. A command that is not mocked gets the
    # run's `on_leak` policy: `fail` stops the node's compile, `allow` runs
    # it and records it. A function that is not mocked runs.
    class Mocks
      class Error < StandardError; end

      ACTIONS = %w[mock allow].freeze

      # The defaults shipped with pupgrade.
      DEFAULTS_FILE = File.expand_path('default_mocks.yaml', __dir__)

      # One `commands` entry.
      #
      # @!attribute [r] match
      #   @return [Regexp]
      # @!attribute [r] action
      #   @return [String] "mock" or "allow"
      # @!attribute [r] stdout
      #   @return [String] what a mocked command prints
      # @!attribute [r] exit
      #   @return [Integer] a mocked command's exit code
      # @!attribute [r] conditions
      #   @return [Hash{String => Array<String>}] dotted fact path to the
      #     values any of which the node must report; empty for any node
      Command = Data.define(:match, :action, :stdout, :exit, :conditions) do
        # @param facts [Hash] the node's facts
        def for?(command_line, facts)
          match.match?(command_line) && conditions.all? { |path, values| values.include?(dig(facts, path).to_s) }
        end

        # The entry with its stdout's `${...}` references resolved for the node.
        def for_node(node)
          return self unless node.is_a?(Enc::Node) && stdout.include?('${')

          with(stdout: Enc.interpolate(stdout, node, 'mock'))
        end

        def dig(facts, path)
          Command.dig(facts, path)
        end

        def self.dig(facts, path)
          path.split('.').reduce(facts) { |v, k| v.is_a?(Hash) ? v[k] : nil }
        end
      end

      # One `functions` entry.
      #
      # @!attribute [r] name
      #   @return [String] the function, "puppetdb_query" or "profile::lookup_ip"
      # @!attribute [r] returns
      #   @return [Object] what a call returns, whatever its arguments
      # @!attribute [r] conditions
      #   @return [Hash{String => Array<String>}] dotted fact path to the
      #     values any of which the node must report; empty for any node
      Function = Data.define(:name, :returns, :conditions) do
        # @param facts [Hash] the node's facts
        def for?(function_name, facts)
          name == function_name && conditions.all? { |path, values| values.include?(Command.dig(facts, path).to_s) }
        end
      end

      # @param path [String] the site's mock file
      # @param defaults [Boolean] whether pupgrade's defaults follow it
      # @return [Mocks]
      # @raise [Error] when the file does not read as a mock file
      def self.load(path, defaults: true)
        data = YAML.safe_load(File.read(path), aliases: true, filename: path) || {}
        raise Error, "#{path}: expected a mapping, got #{data.class}" unless data.is_a?(Hash)

        new(data, path: path, defaults: defaults)
      rescue Errno::ENOENT
        raise Error, "#{path}: no such file"
      rescue Psych::SyntaxError => e
        raise Error, "#{path}: #{e.message}"
      end

      # @return [Mocks] pupgrade's defaults alone, or nothing with
      #   `defaults: false`
      def self.empty(defaults: true)
        new({}, path: nil, defaults: defaults)
      end

      attr_reader :path, :commands, :facts, :functions

      # @return [Array<Array(Regexp, Proc)>] the Ruby file's `mock` blocks,
      #   asked before the entries
      attr_accessor :blocks

      # @return [Array<Array(String, Proc)>] the Ruby file's `function`
      #   blocks, asked before the `functions` entries
      attr_accessor :function_blocks

      # @param data [Hash] the parsed mock file
      def initialize(data, path:, defaults: true)
        @path     = path
        @commands = Array(data['commands']).map { |c| command(c) }
        @facts    = (data['facts'] || {}).to_h { |k, v| [k.to_s, v] }
        @functions = Array(data['functions']).map { |f| function(f) }
        @blocks    = []
        @function_blocks = []
        return unless defaults

        shipped = YAML.safe_load(File.read(DEFAULTS_FILE)) || {}
        @commands += Array(shipped['commands']).map { |c| command(c, DEFAULTS_FILE) }
      end

      # @param command_line [String]
      # @param node [Enc::Node, Hash] the node, or its facts alone
      # @return [Command, nil] the first block or entry answering the command
      #   on this node
      def for_command(command_line, node = {})
        facts = node.is_a?(Enc::Node) ? node.facts : node
        @blocks.each do |pattern, block|
          m = pattern.match(command_line)
          next unless m

          answer = block.call(node, m)
          next if answer.nil?

          stdout, status = answer.is_a?(Hash) ? [answer[:stdout] || answer['stdout'], answer[:exit] || answer['exit']] : [answer, 0]
          return Command.new(match: pattern, action: 'mock', stdout: stdout.to_s, exit: Integer(status || 0), conditions: {})
        end
        @commands.find { |c| c.for?(command_line, facts) }&.for_node(node)
      end

      # @param name [String] the function called
      # @param args [Array] its arguments, for a block
      # @param node [Enc::Node, Hash] the node, or its facts alone
      # @return [Array(Boolean, Object)] whether the call is mocked, and
      #   with what
      def for_function(name, args, node = {})
        name  = name.to_s.delete_prefix('::')
        facts = node.is_a?(Enc::Node) ? node.facts : node
        @function_blocks.each do |wanted, block|
          next unless wanted == name

          answer = block.call(node, *args)
          return [true, answer] unless answer.nil?
        end
        entry = @functions.find { |f| f.for?(name, facts) }
        entry ? [true, entry.returns] : [false, nil]
      end

      # @param name [String] a fact, dotted for a path into a structured one
      # @return [Array(Boolean, Object)] whether the fact is mocked, and with what
      def fact(name)
        return [true, @facts[name]] if @facts.key?(name)

        head, rest = name.split('.', 2)
        return [false, nil] unless rest && @facts.key?(head)

        value = @facts[head]
        rest.split('.').each do |k|
          return [false, nil] unless value.is_a?(Hash) && value.key?(k)

          value = value[k]
        end
        [true, value]
      end

      private

      def function(entry, source = @path)
        raise Error, "#{source}: each function needs a name and what it returns, got #{entry.inspect}" unless entry.is_a?(Hash) && entry['name'] && entry.key?('returns')

        conditions = (entry['when'] || {}).to_h { |k, v| [k.to_s, Array(v).map(&:to_s)] }
        Function.new(name: entry['name'].to_s.delete_prefix('::'), returns: entry['returns'], conditions: conditions)
      end

      def command(entry, source = @path)
        raise Error, "#{source}: each command needs a match, got #{entry.inspect}" unless entry.is_a?(Hash) && entry['match']

        action = (entry['action'] || 'mock').to_s
        raise Error, "#{source}: command action #{action.inspect} is not one of #{ACTIONS.join(', ')}" unless ACTIONS.include?(action)

        conditions = (entry['when'] || {}).to_h { |k, v| [k.to_s, Array(v).map(&:to_s)] }
        Command.new(match: Regexp.new(entry['match'].to_s), action: action, stdout: entry['stdout'].to_s,
                    exit: Integer(entry['exit'] || 0), conditions: conditions)
      rescue ArgumentError, TypeError => e
        raise Error, "#{source}: #{e.message}"
      end
    end
  end
end
