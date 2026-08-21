require 'driftless/detectors/base'
require 'driftless/detectors/exclusions'
require 'driftless/legacy_facts'
module Driftless
  module Detectors
    class HierarchyTiersInterpolatingUnreportedFacts < Base
      include Exclusions::Tiers
      include Exclusions::Facts

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

        findings = []
        corpus.hiera_tiers.each do |tier|
          next if tier.interpolation_vars.empty?
          next if excluded_tier?(tier)

          unreported = tier.interpolation_vars.reject do |var|
            excluded_fact?(var) || nodes.any? { |node| !node.fact(var).nil? }
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
