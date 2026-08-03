require 'set'

require 'driftless/detectors/base'

module Driftless
  module Detectors
    class DataCodebaseMissingClassParam < Base
      key 'data:codebase-missing-class-param'
      about 'Data key references a parameter that does not exist on the referenced class'

      def call
        findings   = []
        exemptions = corpus.lookup_calls.map(&:key).to_set

        corpus.data_files.each do |df|
          df.top_level_keys.each do |key, line|
            next unless key.include?('::')
            next if exemptions.include?(key)

            class_name   = key.rpartition('::')[0]
            param_name   = key.rpartition('::')[2]
            puppet_class = corpus.puppet_classes[class_name]
            next if puppet_class.nil?

            valid_params = puppet_class.params.map(&:name)
            next if valid_params.include?(param_name)

            findings << build_finding(
              path:    df.path,
              line:    line,
              message: "data key #{key.inspect} references parameter #{param_name.inspect} " \
                       "which is not defined on class #{class_name.inspect}",
              meta:    { class_name: class_name, param_name: param_name, valid_params: valid_params },
            )
          end
        end
        findings
      end
    end
  end
end
