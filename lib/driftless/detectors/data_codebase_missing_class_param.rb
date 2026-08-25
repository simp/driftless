require 'set'

require 'driftless/detectors/callable'
require 'driftless/detectors/exclusions'

module Driftless
  module Detectors
    class DataCodebaseMissingClassParam < Callable
      include Exclusions::Classes

      key      'data:codebase-missing-class-param'
      severity :error
      quality  :wrong
      about 'Hiera key refers to non-existent param of a real class'

      config_option :allow_role_profile_keys, type: :boolean, default: false,
        about: 'Permit Hiera-only keys under a role or profile namespace'

      def call
        findings = []

        corpus.data_files.each do |df|
          df.top_level_keys.each do |key, line|
            next unless key.include?('::')

            class_name   = key.rpartition('::')[0]
            next if excluded_class?(class_name)

            param_name   = key.rpartition('::')[2]
            puppet_class = corpus.puppet_classes[class_name]
            next if puppet_class.nil?

            valid_params = puppet_class.params.map(&:name)
            next if valid_params.include?(param_name)
            next if allowed_role_profile_key?(puppet_class, key)

            findings << build_finding(
              path:    df.path,
              line:    line,
              message: "param #{param_name.inspect} " \
                       "not defined in class #{class_name.inspect}",
              meta:    { class_name: class_name, param_name: param_name, valid_params: valid_params },
            )
          end
        end
        findings
      end

      private

      # Requires the explicit lookup() as evidence of intent — without it a
      # misspelled param under a profile would be waved through too.
      def allowed_role_profile_key?(puppet_class, key)
        return false unless option(:allow_role_profile_keys)
        return false unless puppet_class.role? || puppet_class.profile?
        explicit_lookups.include?(key)
      end

      def explicit_lookups
        @explicit_lookups ||=
          (corpus.code_lookup_calls + corpus.data_lookup_calls).map(&:key).to_set
      end
    end
  end
end
