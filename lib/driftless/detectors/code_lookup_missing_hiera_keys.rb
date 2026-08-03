require 'set'

require 'driftless/detectors/base'

module Driftless
  module Detectors
    class CodeLookupMissingHieraKeys < Base
      key 'code:lookup-missing-hiera-keys'
      about 'Explicit lookup() calls searching for keys not defined anywhere in Hiera'

      def call
        defined_keys = collect_defined_keys
        findings     = []

        corpus.lookup_calls.each do |lc|
          next if defined_keys.include?(lc.key)

          findings << build_finding(
            path:    lc.file,
            line:    lc.line,
            message: "lookup call for #{lc.key.inspect} but no top-level key with " \
                     'that name is defined in any Hiera data file',
            meta:    { lookup_key: lc.key, has_default: lc.has_default },
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
