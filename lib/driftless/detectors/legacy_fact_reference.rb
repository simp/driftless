require 'driftless/legacy_facts'

module Driftless
  module Detectors
    # Shared by the two legacy-fact detectors: what counts as a reference to a
    # legacy fact in an interpolation. LegacyFacts itself is a plain lookup, so
    # the prefix policy lives here.
    module LegacyFactReference
      # A legacy fact is a top-scope name, so only the `::` form is a legacy
      # fact reference. A bare name is reported as bare instead — unqualified
      # resolution is the larger defect, and it would be reported twice
      # otherwise.
      def legacy_fact_for(var)
        return nil unless var.start_with?('::')
        ::Driftless::LegacyFacts.match(var.delete_prefix('::'))
      end
    end
  end
end
