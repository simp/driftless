require 'driftless/cli/base'
require 'driftless/cli/root'

module Driftless
  module CLI
    class Config < Base
      register_command name: 'config', subcommand_of: Root
      desc 'Inspect and generate driftless.yaml'
    end
  end
end

Dir[File.join(__dir__, 'config', '*.rb')].sort.each { |f| require f }
