require 'set'

require 'driftless/detectors/callable'
require 'driftless/role_profile'

module Driftless
  module Detectors
    class CodeLookupMissingHieraKeys < Callable
      key      'code:lookup-missing-hiera-keys'
      severity :error
      quality  :wrong
      about '`lookup()` calls for keys not defined anywhere in Hiera'

      config_option :ignore_lookups_with_defaults, type: :boolean, default: false,
        about: 'Skip flagging lookup() calls that provide an explicit default value'

      def call
        defined_keys = collect_defined_keys
        findings     = []

        corpus.code_lookup_calls.each do |lc|
          next if defined_keys.include?(lc.key)
          next if lc.has_default && option(:ignore_lookups_with_defaults)
          next if lc.module_local?

          findings << build_finding(
            path:    lc.file,
            line:    lc.line,
            message: "#{lc.key.inspect} is " \
                     'not defined in any Hiera file',
            meta:    { lookup_key: lc.key, function: lc.function, has_default: lc.has_default },
          )
        end
        findings
      end

      private

      def collect_defined_keys
        keys = Set.new
        corpus.data_files.each { |df| keys.merge(df.top_level_keys.keys) }
        keys.merge(corpus.module_data_keys)
      end
    end
  end
end
