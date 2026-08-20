require 'driftless/cli/base'
require 'driftless/cli/list'
require 'driftless/detectors'

module Driftless
  module CLI
    class List
      class Detectors < Base
        register_command name: 'detectors', subcommand_of: List
        desc 'List all detector keys and their descriptions'

        def execute(_argv)
          registry = ::Driftless::Detectors.registry.sort_by(&:key)
          width = registry.map { |k| k.key.size }.max
          registry.each do |klass|
            puts "#{klass.key.ljust(width)}   #{klass.about}"
          end
          exit 0
        end
      end
    end
  end
end
