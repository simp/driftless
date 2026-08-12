require 'driftless/detectors/base'

module Driftless
  module Detectors
    class HierarchyTiersInterpolatingUnreportedFacts < Base
      key 'hierarchy:tiers-interpolating-unreported-facts'
      about 'Hiera hierarchy tiers whose interpolation vars name facts ' \
            'that no active node reports at all'
      requires_reports 'factsets-for-all-active-nodes'

      def call
        if corpus.reported.missing?('factsets-for-all-active-nodes')
          return [skip_meta_finding(reason: 'no report:factsets-for-all-active-nodes data')]
        end

        nodes = Array(corpus.reported.report('factsets-for-all-active-nodes'))
        # No active nodes → every var would look "unreported"; that's not a
        # meaningful signal (it's an infrastructure question, not a hiera one).
        # Level-2 detector also no-ops in this case; keep the two consistent.
        return [] if nodes.empty?

        findings = []
        corpus.hiera_tiers.each do |tier|
          next if tier.interpolation_vars.empty?

          unreported = tier.interpolation_vars.reject do |var|
            nodes.any? { |node| !node.fact(var).nil? }
          end
          next if unreported.empty?

          findings << build_finding(
            path:    hiera_yaml_path,
            line:    tier.source_line,
            message: "tier #{tier.name.inspect} interpolates fact(s) " \
                     "not reported by any active node: " \
                     "#{unreported.map(&:inspect).join(', ')}",
            meta:    { tier: tier.name, unreported_facts: unreported },
          )
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
