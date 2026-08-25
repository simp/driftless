require 'puppet'

require 'driftless/models/lookup_call'

module Driftless
  # Extracts {LookupCall} records (key, file, line, has_default) from either
  # a parsed Puppet AST (`.extract`) or a YAML data file's scalar values
  # scanned for `%{lookup|alias|hiera(...)}` interpolations
  # (`.extract_from_yaml_values`). Only calls whose first argument is a
  # literal string are extracted; hash-form and dynamic-key calls are ignored.
  class LookupCallExtractor
    LOOKUP_FUNCTIONS       = %w[lookup hiera].freeze
    YAML_LOOKUP_INTERP_RE  = /%\{(?:lookup|alias|hiera)\(\s*['"]([^'"]+)['"]\s*\)\}/.freeze

    def self.extract(program:, file:)
      new(program: program, file: file).extract
    end

    # @param value_lines [Array<Array(String, Integer)>] {HieraDataFileInfo#value_lines}
    def self.extract_from_yaml_values(value_lines, file)
      calls = []
      value_lines.each do |line, lineno|
        line.scan(YAML_LOOKUP_INTERP_RE) do |captured|
          calls << LookupCall.new(
            key:         captured[0],
            file:        file,
            line:        lineno,
            has_default: false,
          )
        end
      end
      calls
    end

    def initialize(program:, file:)
      @program = program
      @file    = file
    end

    def extract
      calls = []
      @program._pcore_all_contents([]) do |node|
        next unless node.is_a?(Puppet::Pops::Model::CallNamedFunctionExpression)
        name = function_name(node)
        next unless LOOKUP_FUNCTIONS.include?(name)

        key = literal_first_arg(node)
        next unless key

        calls << LookupCall.new(
          key:         key,
          file:        @file,
          line:        node.line,
          has_default: default_arg?(node),
        )
      end
      calls
    end

    private

    def function_name(node)
      f = node.functor_expr
      f.respond_to?(:value) ? f.value : nil
    end

    def literal_first_arg(node)
      arg = Array(node.arguments).first
      return nil unless arg.is_a?(Puppet::Pops::Model::LiteralString)
      arg.value
    end

    # True when the call supplies a default value:
    #
    # - either a block form (`lookup('k') |$x| { ... }`)
    # - or a 4th positional arg (`lookup(name, type, merge, default)`)
    #
    # The 2- and 3-arg positional forms do not supply a default
    def default_arg?(node)
      return true if node.respond_to?(:lambda) && !node.lambda.nil?
      Array(node.arguments).length >= 4
    end
  end
end
