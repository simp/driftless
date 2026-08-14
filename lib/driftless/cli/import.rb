require 'driftless/cli/base'
require 'driftless/cli/root'

module Driftless
  module CLI
    class Import < Base
      register_command name: 'import', subcommand_of: Root
      desc 'Import PuppetDB report sessions into the scan ingest tree'

      # Declares `--accept-partial-report-sessions[=A,B,C]` on the given
      # OptionParser, storing the tri-state in options[:accept_partial_report_sessions]:
      #   - nil    → flag not given (strict A+)
      #   - :bare  → bare flag; accept missing summary + any subset
      #   - Array  → list form; expected set = exactly these reports (summary still required)
      # Declared here so Import parent, its leaves, and Scan (§9) can
      # share the identical option shape.
      def self.declare_accept_partial(parser, options)
        parser.on('--accept-partial-report-sessions[=REPORTS]', Array,
                  'Accept partial-report sessions',
                  'Bare: any subset + missing summary; List (=A,B,C): expected set = exactly these') do |v|
          options[:accept_partial_report_sessions] = v || :bare
        end
      end

      protected

      def configure_parser(o)
        self.class.declare_accept_partial(o, @options)
      end
    end
  end
end

Dir[File.join(__dir__, 'import', '*.rb')].sort.each { |f| require f }
