require 'driftless/cli/base'
require 'driftless/cli/root'

module Driftless
  module CLI
    # `driftless modules`: the parent of the module checks.
    class Modules < Base
      register_command name: 'modules', subcommand_of: Root
      desc 'Check the modules a control repo deploys (see subcommands)'
    end
  end
end

Dir[File.join(__dir__, 'modules', '*.rb')].sort.each { |f| require f }
