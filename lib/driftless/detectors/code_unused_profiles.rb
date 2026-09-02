require 'driftless/detectors/callable'
require 'driftless/detectors/exclusions'

module Driftless
  module Detectors
    class CodeUnusedProfiles < Callable
      include Exclusions::Classes

      key      'code:unused-profiles'
      severity :warning
      quality  :stale
      about 'Profile classes not classified by any active node'
      requires_reports 'classes-for-all-active-nodes'

      def call
        if corpus.reported.missing?('classes-for-all-active-nodes')
          return [skip_meta_finding(reason: 'no report:classes-for-all-active-nodes data')]
        end

        active = corpus.reported.all_active_classes
        corpus.puppet_classes.values
          .select(&:profile?)
          .reject { |cls| active.include?(cls.fqname) || excluded_class?(cls.fqname) }
          .sort_by(&:fqname)
          .map do |cls|
            build_finding(
              path:    cls.file,
              message: "profile #{cls.fqname.inspect} is not classified by any active node",
              meta:    { class_name: cls.fqname },
            )
          end
      end
    end
  end
end
