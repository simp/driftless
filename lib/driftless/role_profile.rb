module Driftless
  # Codebase-wide role/profile class-name detection. Config keys
  # `puppet.role_regex` / `puppet.profile_regex` override the defaults.
  #
  # Defaults match "role"/"profile" at start or after any `::` — so both
  # standard (`role::web`) and namespaced (`baseline::role::web`) classes
  # are recognized without config. Site override:
  #
  #   puppet:
  #     role_regex:    '\A(baseline::)?role::'
  #     profile_regex: '\A(baseline::)?profile::'
  module RoleProfile
    DEFAULT_ROLE_RE    = /(?:\A|::)role(?:::|\z)/.freeze
    DEFAULT_PROFILE_RE = /(?:\A|::)profile(?:::|\z)/.freeze

    module_function

    def role?(class_name)
      return false unless class_name
      role_regex.match?(class_name)
    end

    def profile?(class_name)
      return false unless class_name
      profile_regex.match?(class_name)
    end

    def role_regex
      compile(::Driftless.config.dig('puppet', 'role_regex'), DEFAULT_ROLE_RE)
    end

    def profile_regex
      compile(::Driftless.config.dig('puppet', 'profile_regex'), DEFAULT_PROFILE_RE)
    end

    def compile(value, default)
      return default if value.nil?
      value.is_a?(Regexp) ? value : Regexp.new(value.to_s)
    end
  end
end
