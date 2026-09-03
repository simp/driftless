require 'driftless/config_keys'

module Driftless
  # Names a hierarchy tier can interpolate that are top-scope variables, not
  # facts: the ones the codebase sets (site.pp, an ENC), listed under
  # `puppet.top_scope_variables`, plus Puppet's own server variables.
  #
  # The list names them; the mapping form also gives the values a variable
  # takes across the fleet, so a tier interpolating it can be rendered:
  #
  #   puppet:
  #     top_scope_variables:
  #       site_region: [east, west]
  #       compliance_profile:          # name known, values not
  #     allow_builtin_top_scope_variables: true
  module TopScopeVariables
    extend ConfigKeys::DSL

    config_key 'puppet.top_scope_variables', type: :array, default: [],
               about: 'Top-scope variables the codebase sets (site.pp, ENC) that hierarchy tiers ' \
                      'may interpolate; they are not facts, so no factset reports them. A list of ' \
                      'names, or a mapping of name to the values it takes (`site_region: [east, west]`) ' \
                      'so data files under such a tier can be checked for reachability'
    config_key 'puppet.allow_builtin_top_scope_variables', type: :boolean, default: true,
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
      head = name_of(var)
      return true if configured.include?(head)
      return false unless builtin?

      SERVER_VARIABLES.include?(head) || SERVER_NAMESPACES.any? { |ns| head.start_with?("#{ns}::") }
    end

    # The variable name an interpolation refers to: `::site_region` and
    # `site_region.zone` both name `site_region`.
    def name_of(var)
      var.to_s.delete_prefix('::').split('.', 2).first
    end

    # @return [Array<String>] the configured names, from either form
    def configured
      raw = ::Driftless.config.dig('puppet', 'top_scope_variables')
      (raw.is_a?(Hash) ? raw.keys : Array(raw)).map(&:to_s)
    end

    # @param var [String] an interpolation as written in a tier
    # @return [Array<String>, nil] the values configured for it; nil when the
    #   config gives none (the list form, or a name with no values)
    def values(var)
      raw = ::Driftless.config.dig('puppet', 'top_scope_variables')
      return nil unless raw.is_a?(Hash)

      name = name_of(var)
      list = Array(raw[name] || raw[name.to_sym]).map(&:to_s)
      list.empty? ? nil : list
    end

    # Every assignment of configured values to vars, for rendering a template
    # once per assignment.
    #
    # @param vars [Array<String>] interpolations that all have {values}
    # @return [Array<Hash{String => String}>] var to value; `[{}]` for no vars
    def combinations(vars)
      return [{}] if vars.empty?

      lists = vars.map { |var| values(var).map { |value| [var, value] } }
      lists.first.product(*lists.drop(1)).map(&:to_h)
    end

    def builtin?
      value = ::Driftless.config.dig('puppet', 'allow_builtin_top_scope_variables')
      value.nil? ? true : value
    end
  end
end
