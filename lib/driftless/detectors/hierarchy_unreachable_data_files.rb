require 'set'

require 'driftless/detectors/callable'

module Driftless
  module Detectors
    class HierarchyUnreachableDataFiles < Callable
      key      'hierarchy:unreachable-data-files'
      severity :warning
      quality  :impossible
      about 'Hiera data files that are unreachable by every hierarchy tiers\' paths' \
            '(regardless of facts)'

      BACKEND_EXT = {
        yaml_data:  '.yaml',
        json_data:  '.json',
        hocon_data: '.conf',
      }.freeze

      TEMPLATE_VAR_RE = /%\{[^{}]+\}/.freeze

      def call
        findings = []

        # Rendering %{...} as * turns a template into a pattern over the
        # datadir. Braces are alternation in one of Hiera's glob keys and a
        # literal filename in a path, so only a glob tier reads them that way;
        # fnmatch handles *, **, ? and [] under FNM_PATHNAME alone.
        matchers = corpus.hiera_tiers.map do |tier|
          flags  = tier.glob? ? File::FNM_PATHNAME | File::FNM_EXTGLOB : File::FNM_PATHNAME
          [tier.path_templates.map { |t| File.join(tier.datadir, t.gsub(TEMPLATE_VAR_RE, '*')) }, flags]
        end

        all_files = Set.new
        corpus.hiera_tiers.each do |tier|
          ext = BACKEND_EXT[tier.backend]
          next unless ext
          all_files.merge(Dir[File.join(tier.datadir, '**', "*#{ext}")])
        end

        all_files.sort.each do |file|
          reachable = matchers.any? do |patterns, flags|
            patterns.any? { |p| File.fnmatch(p, file, flags) }
          end
          next if reachable

          findings << build_finding(
            path:    file,
            message: "no tier's paths can reach this",

          )
        end
        findings
      end
    end
  end
end
