require 'driftless/version'

module Driftless
  module CLI
    module_function

    def parse(argv)
      case argv.first
      when 'version', '--version'
        puts Driftless::VERSION
        0
      else
        warn "driftless #{Driftless::VERSION} — CLI not yet implemented (scaffolding phase)"
        warn 'Usage will be: driftless scan --repo-dir=DIR --incoming-dir=DIR'
        2
      end
    end
  end
end
