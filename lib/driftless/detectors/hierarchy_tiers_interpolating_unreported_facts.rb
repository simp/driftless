require 'driftless/detectors/base'
require 'driftless/legacy_facts'
module Driftless
  module Detectors
    class HierarchyTiersInterpolatingUnreportedFacts < Base
      key      'hierarchy:tiers-interpolating-unreported-facts'
      severity :warning
      quality  :stale
      about 'Hierarchy tiers interpolating fact names ' \
            'that no active node has reported'
      requires_reports 'factsets-for-all-active-nodes'

      def call
        if corpus.reported.missing?('factsets-for-all-active-nodes')
          return [skip_meta_finding(reason: 'no report:factsets-for-all-active-nodes data')]
        end

        nodes = Array(corpus.reported.report('factsets-for-all-active-nodes'))
        # Prevent case w/no active nodes (every var would look "unreported")
        return [] if nodes.empty?

        exclude_tier_patterns = option(:exclude_tiers)
        exclude_fact_patterns = option(:exclude_facts)

        findings = []
        corpus.hiera_tiers.each do |tier|
          next if tier.interpolation_vars.empty?
          next if exclude_tier_patterns.any? { |pat| File.fnmatch(pat, tier.name.to_s) }

          unreported = tier.interpolation_vars.reject do |var|
            exclude_fact_patterns.any? { |pat| File.fnmatch(pat, var) } ||
              nodes.any? { |node| !node.fact(var).nil? }
          end
          next if unreported.empty?

          noun = 'legacy fact/variable'
          noun = 'legacy fact' if unreported.any? { |x| LegacyFacts.match(x) }
          noun = 'fact' if unreported.any? { |x| x.start_with?('facts.') }
          noun = 'trusted fact' if unreported.all? { |x| x =~ /^trusted\,/ }
          noun.gsub!(%r{/|$}, 's\0') if unreported.size > 1

          findings << build_finding(
            path:    hiera_yaml_path,
            line:    tier.source_line,
            message: "tier #{tier.name.inspect} interpolates #{noun} " \
                     'not reported by any active node: ' \
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
