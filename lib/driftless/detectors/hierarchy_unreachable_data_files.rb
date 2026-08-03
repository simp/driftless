require 'set'

require 'driftless/detectors/base'

module Driftless
  module Detectors
    class HierarchyUnreachableDataFiles < Base
      key 'hierarchy:unreachable-data-files'
      about 'Hiera data files that are unreachable by the Hiera hierarchy ' \
            '(no tier template pattern could match, regardless of facts)'

      BACKEND_EXT = {
        yaml_data:  '.yaml',
        json_data:  '.json',
        hocon_data: '.conf',
      }.freeze

      TEMPLATE_VAR_RE = /%\{[^{}]+\}/.freeze

      def call
        findings = []

        globs_by_tier = corpus.hiera_tiers.map do |tier|
          [tier, tier.path_templates.map { |t| File.join(tier.datadir, t.gsub(TEMPLATE_VAR_RE, '*')) }]
        end

        all_files = Set.new
        corpus.hiera_tiers.each do |tier|
          ext = BACKEND_EXT[tier.backend]
          next unless ext
          all_files.merge(Dir[File.join(tier.datadir, '**', "*#{ext}")])
        end

        all_files.sort.each do |file|
          reachable = globs_by_tier.any? do |_tier, globs|
            globs.any? { |g| File.fnmatch(g, file, File::FNM_PATHNAME) }
          end
          next if reachable

          findings << build_finding(
            path:    file,
            message: "no hierarchy tier template pattern could reach #{file} " \
                     '(fact-independent structural check)',
          )
        end
        findings
      end
    end
  end
end
