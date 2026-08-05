require 'driftless/cli/base'
require 'driftless/cli/root'

module Driftless
  module CLI
    class List < Base
      register_command name: ['list', 'ls'], subcommand_of: Root
      desc 'List things (see subcommands)'
    end
  end
end

Dir[File.join(__dir__, 'list', '*.rb')].sort.each { |f| require f }
