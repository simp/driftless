require 'puppet'

require 'driftless/models/lookup_call'

module Driftless
  class LookupCallExtractor
    LOOKUP_FUNCTIONS       = %w[lookup hiera].freeze
    YAML_LOOKUP_INTERP_RE  = /%\{(?:lookup|alias|hiera)\(\s*['"]([^'"]+)['"]\s*\)\}/.freeze

    def self.extract(program:, file:)
      new(program: program, file: file).extract
    end

    def self.extract_from_yaml_source(source, file)
      calls = []
      source.each_line.with_index(1) do |line, lineno|
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
          has_default: Array(node.arguments).length >= 2,
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
  end
end
