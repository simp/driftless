require 'set'

require 'driftless/detectors/base'
require 'driftless/hierarchy_interpolator'

module Driftless
  module Detectors
    class HierarchyFilesMissedByReportedFactValues < Base
      key 'hierarchy:files-missed-by-reported-fact-values'
      about 'Hiera data files on disk that no hierarchy tier resolves to ' \
            'given any active node\'s reported facts'
      requires_reports 'factsets-for-all-active-nodes'

      BACKEND_EXT = {
        yaml_data:  '.yaml',
        json_data:  '.json',
        hocon_data: '.conf',
      }.freeze

      TEMPLATE_VAR_RE = /%\{[^{}]+\}/.freeze

      def call
        if corpus.reported.missing?('factsets-for-all-active-nodes')
          return [skip_meta_finding(reason: 'no report:factsets-for-all-active-nodes data')]
        end

        nodes = Array(corpus.reported.report('factsets-for-all-active-nodes'))

        findings          = []
        reachable         = Set.new
        excluded_by_tiers = Set.new

        corpus.hiera_tiers.each do |tier|
          tier_reachable = reachable_paths_for(tier, nodes)

          if tier.interpolation_vars.any? && tier_reachable.empty?
            # A tier whose interpolation vars are satisfied by NO active node's facts.
            # Meta finding disabled until a severity/priority scheme exists — this
            # is informational, not a bug. See `hierarchy:tiers-interpolating-unreported-facts`
            # in the issue catalog. The exclusion below is not for reporting; it
            # prevents the unresolvable tier's datadir subset from being flood-reported
            # by the main pass.
            excluded_by_tiers.merge(would_match_files(tier))
          else
            reachable.merge(tier_reachable)
          end
        end

        on_disk = files_on_disk(corpus.hiera_tiers)
        orphans = (on_disk - reachable - excluded_by_tiers).sort

        orphans.each do |path|
          findings << build_finding(
            path:    path,
            message: 'no reported fact can resolve any hierarchy tier to this path',
          )
        end

        findings
      end

      private

      def reachable_paths_for(tier, nodes)
        paths = Set.new
        tier.path_templates.each do |template|
          if tier.interpolation_vars.empty?
            paths << File.join(tier.datadir, template)
          else
            nodes.each do |node|
              rendered = HierarchyInterpolator.new(node).render(template)
              next if HierarchyInterpolator.unresolved?(rendered)
              paths << File.join(tier.datadir, rendered)
            end
          end
        end
        paths
      end

      def would_match_files(tier)
        matches = Set.new
        tier.path_templates.each do |template|
          glob = template.gsub(TEMPLATE_VAR_RE, '*')
          matches.merge(Dir[File.join(tier.datadir, glob)])
        end
        matches
      end

      def files_on_disk(tiers)
        files = Set.new
        tiers.each do |tier|
          ext = BACKEND_EXT[tier.backend]
          next unless ext
          files.merge(Dir[File.join(tier.datadir, '**', "*#{ext}")])
        end
        files
      end
    end
  end
end
