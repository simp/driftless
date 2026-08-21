require 'set'

require 'driftless/detectors/base'
require 'driftless/detectors/exclusions'

module Driftless
  module Detectors
    class HierarchyTiersInterpolatingBareVariables < Base
      include Exclusions::Tiers
      include Exclusions::Facts

      key      'hierarchy:tiers-interpolating-bare-variables'
      severity :warning
      quality  :weird
      about 'Hierarchy tiers interpolating an unqualified variable, which can ' \
            'resolve to a local variable instead of the intended value'

      # `facts.` and `trusted.` index a global structure, so they resolve
      # deterministically.
      STRUCTURED_PREFIXES = %w[facts. trusted.].freeze

      # `%{lookup('x')}` and friends are Hiera function calls, not variables.
      FUNCTION_CALL = /\(/.freeze

      def call
        findings = []
        corpus.hiera_tiers.each do |tier|
          next if excluded_tier?(tier)

          seen = Set.new
          tier.interpolation_vars.each do |var|
            next unless bare?(var)
            next if excluded_fact?(var)
            next unless seen.add?(var)

            findings << build_finding(
              path:    hiera_yaml_path,
              line:    tier.source_line,
              message: "hierarchy tier #{tier.name.inspect} interpolates #{var.inspect} " \
                       "unqualified (use %{::#{var}} for a top-scope variable)",
              meta:    { tier: tier.name, interpolation: var },
            )
          end
        end
        findings
      end

      private

      # Any `::` qualifies the name — leading for top scope, embedded for a
      # class namespace — and either way it is not a local variable.
      def bare?(var)
        return false if var.match?(FUNCTION_CALL)
        return false if var.include?('::')
        STRUCTURED_PREFIXES.none? { |p| var.start_with?(p) }
      end

      def hiera_yaml_path
        corpus.repo_dir && File.join(corpus.repo_dir, 'hiera.yaml')
      end
    end
  end
end
