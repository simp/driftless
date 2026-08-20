require 'set'

require 'driftless/detectors/base'

module Driftless
  module Detectors
    class DataCodebaseMissingClass < Base
      key      'data:codebase-missing-class'
      severity :error
      quality  :wrong
      about 'Hiera key references a class not defined in the codebase'

      def call
        findings   = []
        # Direct lookup() calls from Puppet or Hiera are exempt:
        # Someone is looking for that key intentionally, even if it doesn't map
        # to a real class - it might be a Hiera-only namespace.
        exemptions = (corpus.code_lookup_calls + corpus.data_lookup_calls).map(&:key).to_set

        corpus.data_files.each do |df|
          df.top_level_keys.each do |key, line|
            next unless key.include?('::')
            next if exemptions.include?(key)

            class_name = key.rpartition('::')[0]
            next if corpus.puppet_classes.key?(class_name)

            findings << build_finding(
              path:    df.path,
              line:    line,
              message: "#{key.inspect} references class #{class_name.inspect} " \
                       'which is not defined anywhere in the codebase',
              meta:    { class_name: class_name },
            )
          end
        end
        findings
      end
    end
  end
end
