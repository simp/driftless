require 'driftless/detectors/callable'
require 'driftless/detectors/legacy_fact_reference'
require 'driftless/legacy_facts'

module Driftless
  module Detectors
    class DataLegacyFacts < Callable
      include LegacyFactReference

      key      'data:legacy-facts'
      severity :error
      quality  :wrong
      about 'Hiera data files that interpolate legacy facts' \
            '(%{osfamily}, %{hostname}, etc.) instead of the modern structured equivalents'

      # Line-by-line scan matches bare `%{...}` in value positions.
      # Multi-line scalar values with legacy fact interpolations will still be
      # caught, but the reported line points to whichever contained the pattern.
      INTERPOLATION_RE = /%\{\s*([^{}\s]+)\s*\}/.freeze

      def call
        findings = []
        corpus.data_files.each do |df|
          df.source.each_line.with_index(1) do |line, lineno|
            line.scan(INTERPOLATION_RE).each do |(inner)|
              legacy = legacy_fact_for(inner)
              next unless legacy

              modern = LegacyFacts::MAP[legacy]
              findings << build_finding(
                path:    df.path,
                line:    lineno,
                message: "interpolates legacy fact %{#{inner}} " \
                         "(modern equivalent: %{facts.#{modern}})",
                meta:    { legacy: legacy, modern: modern, interpolation: inner },
              )
            end
          end
        end
        findings
      end
    end
  end
end
