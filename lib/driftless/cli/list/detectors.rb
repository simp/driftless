require 'driftless/cli/base'
require 'driftless/cli/list'
require 'driftless/detectors'
require 'driftless/ansi'

module Driftless
  module CLI
    class List
      class Detectors < Base
        register_command name: 'detectors', subcommand_of: List
        desc 'List all detector keys and their descriptions'

        include Ansi

        def execute(_argv)
          registry = ::Driftless::Detectors.registry.sort_by(&:key)
          width = registry.map { |k| k.key.size }.max
          registry.each do |klass|
            title_column = klass.key.ljust(width)
            about_column = klass.about
            if ::Driftless::Ansi.enabled?($stdout)
              title_column = Ansi.wrap(title_column, :bold)
              about_column = Ansi.wrap(about_column, :cyan)
            end
            puts "#{title_column}   #{about_column}"
          end
          exit 0
        end
      end
    end
  end
end
