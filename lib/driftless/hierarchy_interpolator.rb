require 'driftless/models/node'

module Driftless
  class HierarchyInterpolator
    UnresolvedInterpolation = Object.new.freeze

    INTERPOLATION_RE = /%\{([^{}]+)\}/.freeze

    def self.unresolved?(value)
      value.equal?(UnresolvedInterpolation)
    end

    def initialize(node)
      @node = node
    end

    def render(template)
      unresolved = false
      rendered = template.to_s.gsub(INTERPOLATION_RE) do
        value = @node.fact(Regexp.last_match(1).strip)
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
