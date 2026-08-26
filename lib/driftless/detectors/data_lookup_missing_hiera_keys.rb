require 'set'

require 'driftless/detectors/callable'

module Driftless
  module Detectors
    class DataLookupMissingHieraKeys < Callable
      key      'data:lookup-missing-hiera-keys'
      severity :error
      quality  :wrong
      about 'Hiera value interpolations (%{lookup(...)}, %{alias(...)}, ' \
            '%{hiera(...)}) referencing keys not defined anywhere in Hiera'

      def call
        defined_keys = collect_defined_keys
        findings     = []

        corpus.data_lookup_calls.each do |lc|
          next if defined_keys.include?(lc.key)

          findings << build_finding(
            path:    lc.file,
            line:    lc.line,
            message: "#{lc.key.inspect} not defined in any Hiera file (via #{lc.function})",
            meta:    { lookup_key: lc.key, function: lc.function },
          )
        end
        findings
      end

      private

      def collect_defined_keys
        keys = Set.new
        corpus.data_files.each { |df| keys.merge(df.top_level_keys.keys) }
        keys
      end
    end
  end
end
