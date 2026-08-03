require 'set'

require 'driftless/detectors/base'

module Driftless
  module Detectors
    class DataCodebaseMissingClass < Base
      key 'data:codebase-missing-class'
      about 'Data key references class::param where the class is not defined in the control repo'

      def call
        findings   = []
        exemptions = corpus.lookup_calls.map(&:key).to_set

        corpus.data_files.each do |df|
          df.top_level_keys.each do |key, line|
            next unless key.include?('::')
            next if exemptions.include?(key)

            class_name = key.rpartition('::')[0]
            next if corpus.puppet_classes.key?(class_name)

            findings << build_finding(
              path:    df.path,
              line:    line,
              message: "data key #{key.inspect} references class #{class_name.inspect} " \
                       'which is not defined anywhere in the control repo',
              meta:    { class_name: class_name },
            )
          end
        end
        findings
      end
    end
  end
end
