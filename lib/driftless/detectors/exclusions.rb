module Driftless
  module Detectors
    # Exclusion controls for detectors that can act on them. Each module
    # declares its config option on the including class and supplies the
    # predicate that honors it.
    module Exclusions
      # For detectors whose findings name a hierarchy tier.
      module Tiers
        def self.included(klass)
          klass.config_option :exclude_tiers, type: :array, default: [],
            about: 'List (of glob patterns) of Hiera tier names to skip'
        end

        def excluded_tier?(tier)
          option(:exclude_tiers).any? { |pat| File.fnmatch(pat, tier.name.to_s) }
        end
      end

      # For detectors whose findings name a fact or interpolated variable.
      module Facts
        def self.included(klass)
          klass.config_option :exclude_facts, type: :array, default: [],
            about: 'List (of glob patterns) of fact/variable names to skip'
        end

        # Takes every name that denotes the same fact — `facts.osfamily` and the
        # `osfamily` it resolves to — so a pattern matching any one excludes it.
        def excluded_fact?(*names)
          patterns = option(:exclude_facts)
          return false if patterns.empty?
          names.compact.any? { |name| patterns.any? { |pat| File.fnmatch(pat, name.to_s) } }
        end
      end
    end
  end
end
