require 'set'

require 'driftless/detectors/base'

module Driftless
  module Detectors
    class DataLookupMissingHieraKeys < Base
      key 'data:lookup-missing-hiera-keys'
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
            message: "hiera value interpolation for #{lc.key.inspect} but no top-level key " \
                     'with that name is defined in any Hiera data file',
            meta:    { lookup_key: lc.key },
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
