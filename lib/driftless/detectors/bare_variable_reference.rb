module Driftless
  module Detectors
    # What counts as a bare variable reference
    module BareVariableReference
      # Each indexes a global structure, so the reference resolves
      # deterministically.
      STRUCTURED_PREFIXES = %w[facts. trusted. server_facts.].freeze

      # `%{lookup('x')}` and friends are Hiera function calls, not variables.
      FUNCTION_CALL = /\(/.freeze

      # puppet-injected variables, visible from a server compile (including hiera)
      # They are available as bare variables and keys in $facts/$trusted
      AGENT_BUILTIN_VARIABLES = {
        # prefer trusted.certname to facts.clientcert (and facts.fqdn)
        'clientcert' => 'trusted.certname', 
        'clientversion' =>'facts.clientversion',
        'puppetversion' => 'facts.puppetversion',
        'clientnoop' => 'facts.clientnoop',
        # only set when agent sets its own environment (in puppet.conf, cli flag)
        'agent_specified_environment' => 'facts.agent_specified_environment',
      }
      # server-injected variables, ONLY visible in server compiles (including hiera)
      # They are all available as bare variables 
      SERVER_BUILTIN_VARIABLES = {
        'environment' => 'server_facts.environment',
        'serverip' => 'server_facts.serverip',
        'serverversion' => 'server_facts.serverversion',
        'servername' => 'server_facts.servername',
        'serverip6' => 'server_facts.serverip6',
        # Probably only available in openvox, have not yet confirmed
        'serverimplementation' => 'server_facts.serverimplementation',
      }
      
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
