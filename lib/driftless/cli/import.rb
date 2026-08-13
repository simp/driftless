require 'driftless/cli/base'
require 'driftless/cli/root'

module Driftless
  module CLI
    class Import < Base
      register_command name: 'import', subcommand_of: Root
      desc 'Import PuppetDB report sessions into the scan ingest tree'
    end
  end
end

Dir[File.join(__dir__, 'import', '*.rb')].sort.each { |f| require f }
