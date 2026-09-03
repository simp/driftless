require 'driftless/models/node'

module Driftless
  # Renders a tier's path template for one node.
  class HierarchyInterpolator
    UnresolvedInterpolation = Object.new.freeze

    INTERPOLATION_RE = /%\{([^{}]+)\}/.freeze

    def self.unresolved?(value)
      value.equal?(UnresolvedInterpolation)
    end

    # @param node [Node, nil] answers each interpolation via #fact
    # @param overrides [Hash{String => String}] values answered before the
    #   node is asked, keyed by the interpolation as written (`::site_region`)
    def initialize(node, overrides = {})
      @node      = node
      @overrides = overrides
    end

    # @return [String, UnresolvedInterpolation] the rendered path, or the
    #   marker when any interpolation has no value
    def render(template)
      unresolved = false
      rendered = template.to_s.gsub(INTERPOLATION_RE) do
        name  = Regexp.last_match(1).strip
        value = @overrides.fetch(name) { @node&.fact(name) }
        if value.nil?
          unresolved = true
          ''
        else
          value.to_s
        end
      end
      unresolved ? UnresolvedInterpolation : rendered
    end
  end
end
