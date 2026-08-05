require 'set'

require 'driftless/detectors/base'
require 'driftless/legacy_facts'

module Driftless
  module Detectors
    class HierarchyLegacyFacts < Base
      key 'hierarchy:legacy-facts'
      about 'Hiera hierarchy tiers that interpolate legacy Facter fact names ' \
            '(osfamily, hostname, etc.) rather than the modern structured equivalents'

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
              message: "hierarchy tier #{tier.name.inspect} interpolates legacy fact " \
                       "#{legacy.inspect} (modern equivalent: #{modern.inspect})",
              meta: { tier: tier.name, legacy: legacy, modern: modern, interpolation: var },
            )
          end
        end
        findings
      end
    end
  end
end
