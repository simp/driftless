module Driftless
  module Detectors
    # Shared by the hierarchy and data bare-variable detectors: what counts as
    # an unqualified interpolation.
    module BareVariableReference
      # `facts.` and `trusted.` index a global structure, so they resolve
      # deterministically.
      STRUCTURED_PREFIXES = %w[facts. trusted.].freeze

      # `%{lookup('x')}` and friends are Hiera function calls, not variables.
      FUNCTION_CALL = /\(/.freeze

      # Any `::` qualifies the name — leading for top scope, embedded for a
      # class namespace — and either way it is not a local variable.
      def bare?(var)
        return false if var.match?(FUNCTION_CALL)
        return false if var.include?('::')
        STRUCTURED_PREFIXES.none? { |p| var.start_with?(p) }
      end
    end
  end
end
