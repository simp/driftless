require 'driftless/cli/base'
require 'driftless/cli/root'

module Driftless
  module CLI
    class Help < Base
      register_command name: 'help', subcommand_of: Root
      desc 'Show help for a command (e.g. `driftless help scan`)'

      def run(argv)
        argv = argv.dup

        # `driftless help --help` — describe ourselves, don't try to walk.
        if %w[-h --help].include?(argv.first)
          print_help
          exit 0
        end

        cursor = Root
        path   = []
        until argv.empty?
          sub_name = argv.shift
          child =
            begin
              cursor.find_subcommand(sub_name)
            rescue Base::AmbiguousSubcommand => e
              ::Driftless.logger.fatal(e.message)
              Root.new.print_help($stderr)
              exit 2
            end

          unless child
            ::Driftless.logger.fatal("unknown command: #{(path + [sub_name]).join(' ')}")
            Root.new.print_help($stderr)
            exit 2
          end
          cursor = child
          path << sub_name
        end

        cursor.new.print_help
        exit 0
      end
    end
  end
end
