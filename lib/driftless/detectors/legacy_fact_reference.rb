require 'driftless/legacy_facts'

module Driftless
  module Detectors
    # Shared by the two legacy-fact detectors: what counts as a reference to a
    # legacy fact in an interpolation. LegacyFacts itself is a plain lookup, so
    # the prefix policy lives here.
    module LegacyFactReference
      # `facts.` and `trusted.` are structured accessors, so whatever follows
      # is a structured fact by construction and never a legacy one.
      STRUCTURED_PREFIXES = %w[facts. trusted.].freeze

      def legacy_fact_for(var)
        return nil if STRUCTURED_PREFIXES.any? { |p| var.start_with?(p) }
        ::Driftless::LegacyFacts.match(var.delete_prefix('::'))
      end
    end
  end
end
