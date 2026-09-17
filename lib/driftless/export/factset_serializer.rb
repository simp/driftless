require 'json'
require 'yaml'

module Driftless
  module Export
    # Turns a node's facts into the file body one export profile writes.
    # The including class supplies `@profile` and `@serialization`.
    module FactsetSerializer
      private

      def payload(node)
        facts = deep_dup(node.facts || {})
        add_identity_facts!(facts, node.certname) if @profile == 'lookup'
        facts
      end

      # Fills each identity fact only where absent; existing top-level values
      # are left untouched.
      def add_identity_facts!(facts, certname)
        net    = facts['networking'].is_a?(Hash) ? facts['networking'] : {}
        fqdn   = net['fqdn'] || certname.to_s
        parts  = fqdn.split('.', 2)
        facts['hostname']   ||= net['hostname'] || parts.first
        facts['domain']     ||= net['domain']   || (parts[1] || '')
        facts['fqdn']       ||= fqdn
        facts['clientcert'] ||= certname.to_s
      end

      def serialize(data)
        case @serialization
        when 'json' then JSON.pretty_generate(data) + "\n"
        when 'yaml' then YAML.dump(data)
        end
      end

      def deep_dup(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
        when Array then obj.map { |v| deep_dup(v) }
        else obj
        end
      end
    end
  end
end
