require 'driftless/config_keys'

module Driftless
  # Names a hierarchy tier can interpolate that are top-scope variables, not
  # facts: the ones the codebase sets (site.pp, an ENC), listed under
  # `puppet.top_scope_variables`, plus Puppet's own server variables.
  #
  #   puppet:
  #     top_scope_variables: [site_region, compliance_profile]
  #     builtin_top_scope_variables: true
  module TopScopeVariables
    extend ConfigKeys::DSL

    config_key 'puppet.top_scope_variables', type: :array, default: [],
               about: 'Top-scope variables the codebase sets (site.pp, ENC) that hierarchy tiers ' \
                      'may interpolate; they are not facts, so no factset reports them'
    config_key 'puppet.builtin_top_scope_variables', type: :boolean, default: true,
               about: "Treat Puppet's server variables (environment, servername, serverip, " \
                      'serverversion, server_facts, settings::*) as top-scope variables'

    # Set by the compiling server, never present in a factset. From
    # lang_facts_and_builtin_vars, "Server variables".
    SERVER_VARIABLES = %w[environment servername serverip serverversion server_facts].freeze
    SERVER_NAMESPACES = %w[settings].freeze

    module_function

    # @param var [String] an interpolation as written in a tier, e.g.
    #   `::site_region`, `server_facts.environment`, `settings::strict_variables`
    def known?(var)
      head = var.to_s.delete_prefix('::').split('.', 2).first
      return true if configured.include?(head)
      return false unless builtin?

      SERVER_VARIABLES.include?(head) || SERVER_NAMESPACES.any? { |ns| head.start_with?("#{ns}::") }
    end

    def configured
      Array(::Driftless.config.dig('puppet', 'top_scope_variables')).map(&:to_s)
    end

    def builtin?
      value = ::Driftless.config.dig('puppet', 'builtin_top_scope_variables')
      value.nil? ? true : value
    end
  end
end
