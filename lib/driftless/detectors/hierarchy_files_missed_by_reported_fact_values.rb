require 'set'

require 'driftless/detectors/callable'
require 'driftless/hierarchy_interpolator'
require 'driftless/node_grouping'

module Driftless
  module Detectors
    class HierarchyFilesMissedByReportedFactValues < Callable
      key      'hierarchy:files-missed-by-reported-fact-values'
      severity :warning
      quality  :stale
      about 'Hiera data files that a tier *could* reach but won\'t, ' \
            'because no reported value for the required fact matches'
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

        reachable         = Set.new
        excluded_by_tiers = Set.new
        # One walk of the node list, shared by every path in the hierarchy.
        grouping = NodeGrouping.new(nodes, corpus.hiera_tiers.flat_map(&:interpolation_vars).uniq)

        corpus.hiera_tiers.each do |tier|
          tier_reachable = reachable_paths_for(tier, grouping)

          if tier.interpolation_vars.any? && tier_reachable.empty?
            # A tier whose interpolation vars are satisfied by NO active node's facts.

            #  The exclusion below is not for reporting; it prevents this tier's
            #  datadir subset from being flood-reported at file-scope by the
            #  main pass here.
            excluded_by_tiers.merge(would_match_files(tier))
          else
            reachable.merge(tier_reachable)
          end
        end

        on_disk = files_on_disk(corpus.hiera_tiers)
        orphans = (on_disk - reachable - excluded_by_tiers).sort

        orphans.map do |path|
          tier, vars = interpolated_vars_for(path)
          if vars
            noun = vars.size > 1 ? 'combination' : 'value'
            build_finding(
              path:    path,
              message: "no reported #{noun} of #{vars.join(' and ')} resolves this path",
              meta:    { tier: tier.name, vars: vars },
            )
          end
        end.compact
      end

      private

      # The first tier whose interpolated template shape the file matches, and
      # that template's variables. Matched the way
      # hierarchy:unreachable-data-files matches: %{...} as *, braces as
      # alternation only under a glob locator.
      # @return [Array(HieraTier, Array<String>), nil]
      def interpolated_vars_for(path)
        corpus.hiera_tiers.each do |tier|
          flags = tier.glob? ? File::FNM_PATHNAME | File::FNM_EXTGLOB : File::FNM_PATHNAME
          tier.path_templates.each do |template|
            vars = tier.vars_for(template)
            next if vars.empty?

            pattern = File.join(tier.datadir, template.gsub(TEMPLATE_VAR_RE, '*'))
            return [tier, vars] if File.fnmatch(pattern, path, flags)
          end
        end
        nil
      end

      # Renders each path once per distinct set of values for the variables
      # that path interpolates.
      def reachable_paths_for(tier, grouping)
        paths = Set.new
        tier.path_templates.each do |template|
          vars = tier.vars_for(template)
          if vars.empty?
            paths.merge(locations_for(tier, template))
            next
          end

          grouping.representatives(vars).each do |node|
            rendered = HierarchyInterpolator.new(node).render(template)
            next if HierarchyInterpolator.unresolved?(rendered)
            paths.merge(locations_for(tier, rendered))
          end
        end
        paths
      end

      # What one rendered level reaches under the tier's datadir. A path
      # names a single file; a glob names whatever is on disk, expanded here
      # as Hiera's expand_globs does, directories excluded.
      def locations_for(tier, rendered)
        full = File.join(tier.datadir, rendered)
        return [full] unless tier.glob?

        Dir[full].reject { |path| File.directory?(path) }
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
