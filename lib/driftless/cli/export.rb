require 'driftless/cli/base'
require 'driftless/cli/root'

module Driftless
  module CLI
    class Export < Base
      register_command name: 'export', subcommand_of: Root
      desc 'Export scan-side data for downstream tools'
    end
  end
end

Dir[File.join(__dir__, 'export', '*.rb')].sort.each { |f| require f }
