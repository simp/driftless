require 'driftless/version'
require 'driftless/cli/base'

module Driftless
  module CLI
    class Root < Base
      register_command name: 'driftless'
      desc 'Puppet/OpenVox control-repo linter'

      protected

      def configure_parser(o)
        o.on('--version', 'Print the driftless version') do
          puts Driftless::VERSION
          exit 0
        end
      end
    end
  end
end

# Load Root's siblings — each child registers itself via subcommand_of Root.
Dir[File.join(__dir__, '*.rb')].sort.each do |file|
  next if %w[base.rb root.rb].include?(File.basename(file))
  require file
end
