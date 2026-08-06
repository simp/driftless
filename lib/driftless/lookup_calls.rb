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
          has_default: has_default_arg?(node),
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

    # Signature-aware detection of "does this lookup call supply a default?"
    # Puppet's lookup()/hiera() default surface in three forms:
    #   1. Block form:  lookup('k') |$x| { 'fallback' }        — lambda present
    #   2. 4th positional: lookup(name, type, merge, default)   — args.length >= 4
    #   3. Hash form:   lookup({'name' => 'k', 'default_value' => ...})
    # The 2-arg form (name, type) and 3-arg form (name, type, merge) do NOT
    # supply a default — a widespread confusion caught only when a consumer
    # (config option ignore_lookups_with_defaults) surfaced the misclassification.
    def has_default_arg?(node)
      return true if node.respond_to?(:lambda) && !node.lambda.nil?

      args = Array(node.arguments)
      return true if args.length >= 4

      # Hash form: lookup({'name' => 'k', 'default_value' => ...}).
      # Currently defensive-not-reachable: literal_first_arg() filters non-
      # LiteralString first args before we build a LookupCall at all, so
      # hash-form calls never reach has_default_arg?. If extractor support
      # for hash-form is added later, this branch already gives the right
      # answer without further change.
      if args.length == 1 && args.first.is_a?(Puppet::Pops::Model::LiteralHash)
        return args.first.entries.any? do |entry|
          entry.key.respond_to?(:value) && entry.key.value.to_s == 'default_value'
        end
      end

      false
    end
  end
end
