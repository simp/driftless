require 'set'

require 'driftless/detectors/callable'
require 'driftless/detectors/bare_variable_reference'
require 'driftless/detectors/exclusions'

module Driftless
  module Detectors
    class HierarchyTiersInterpolatingBareVariables < Callable
      include BareVariableReference
      include Exclusions::Tiers
      include Exclusions::Facts

      key      'hierarchy:tiers-interpolating-bare-variables'
      severity :warning
      quality  :weird
      about 'Hierarchy tiers that interpolate bare variables, which can ' \
            'resolve to a local variable instead of the intended value'

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
              message: "#{tier.name.inspect} interpolates bare variable #{var.inspect} ",
              meta:    { tier: tier.name, interpolation: var },
            )
          end
        end
        findings
      end

      private

      def hiera_yaml_path
        corpus.repo_dir && File.join(corpus.repo_dir, 'hiera.yaml')
      end
    end
  end
end
