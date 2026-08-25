require 'driftless/detectors/bare_variable_reference'
require 'driftless/detectors/callable'

module Driftless
  module Detectors
    class DataBareVariables < Callable
      include BareVariableReference

      key      'data:bare-variables'
      severity :warning
      quality  :weird
      about 'Hiera data values interpolating an unqualified variable, which ' \
            'can resolve to a local variable instead of the intended value'

      INTERPOLATION_RE = /%\{\s*([^{}\s]+)\s*\}/.freeze

      def call
        findings = []
        corpus.data_files.each do |df|
          df.value_lines.each do |line, lineno|
            line.scan(INTERPOLATION_RE).each do |(inner)|
              next unless bare?(inner)

              findings << build_finding(
                path:    df.path,
                line:    lineno,
                message: "interpolates bare variable %{#{inner}}",
                meta:    { interpolation: inner },
              )
            end
          end
        end
        findings
      end
    end
  end
end
