require 'set'

require 'driftless/detectors/base'
require 'driftless/legacy_facts'

module Driftless
  module Detectors
    class HierarchyLegacyFacts < Base
      key 'hierarchy:legacy-facts'
      about 'Hierarchy tiers that interpolate legacy facts ' \
            '(osfamily, fqdn, etc.) instead of structured facts'

      def call
        findings = []
        corpus.hiera_tiers.each do |tier|
          seen = Set.new
          tier.interpolation_vars.each do |var|
            legacy = LegacyFacts.match(var)
            next unless legacy
            next unless seen.add?(legacy)

            modern = LegacyFacts::MAP[legacy]
            findings << build_finding(
              path:    hiera_yaml_path,
              line:    tier.source_line,
              message: "hierarchy tier #{tier.name.inspect} interpolates legacy fact " \
                       "#{legacy.inspect} (modern equivalent: #{modern.inspect})",
              meta:    { tier: tier.name, legacy: legacy, modern: modern, interpolation: var },
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
