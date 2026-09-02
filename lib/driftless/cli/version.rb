require 'driftless/version'
require 'driftless/cli/base'
require 'driftless/cli/root'

module Driftless
  module CLI
    class Version < Base
      register_command name: 'version', subcommand_of: Root
      desc 'Print the driftless version'
      skip_config_load

      def execute(_argv)
        puts Driftless::VERSION
        exit 0
      end
    end
  end
end
