require 'driftless/cli/base'
require 'driftless/cli/list'
require 'driftless/cli/table'
require 'driftless/inputs/report_index'

module Driftless
  module CLI
    class List
      # `driftless list reports`
      #
      # One row per report file in the incoming tree, live sessions first,
      # then what `import cleanup` archived and quarantined.
      class Reports < Base
        include Table

        register_command name: 'reports', subcommand_of: List
        desc 'List report files across live, archived, and quarantined sessions, with sizes'

        COLUMNS = %w[state collector session report size].freeze
        UNITS   = %w[B KiB MiB GiB TiB].freeze

        def execute(_argv)
          require_incoming_dir!
          incoming_dir = File.expand_path(@options[:incoming_dir])
          fatal!("incoming-dir not readable: #{incoming_dir}", 3) unless File.directory?(incoming_dir)

          entries = ::Driftless::Inputs::ReportIndex.list(incoming_dir)
          rows = entries.map { |e| [e.state, e.collector, e.session_id, e.report, size(e.bytes)] }
          print_table(COLUMNS, rows)
          puts "total #{size(entries.sum(&:bytes))} in #{entries.size} file(s)" unless entries.empty?
          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-i', '--incoming-dir=DIR',
               'Path to the incoming PuppetDB reports directory tree',
               'Default: reports.incoming_dir from driftless.yaml') { |v| @options[:incoming_dir] = v }
        end

        private

        def require_incoming_dir!
          return if @options[:incoming_dir]
          fatal!('list reports: --incoming-dir required (or set reports.incoming_dir in driftless.yaml)', help: true)
        end

        def config_defaults
          { incoming_dir: ::Driftless.config.dig('reports', 'incoming_dir') }.compact
        end

        # Bytes in the largest unit that keeps the number under 1024, one decimal.
        def size(bytes)
          unit = 0
          value = bytes.to_f
          while value >= 1024 && unit < UNITS.length - 1
            value /= 1024
            unit += 1
          end
          unit.zero? ? "#{bytes} B" : '%.1f %s' % [value, UNITS[unit]]
        end
      end
    end
  end
end
