require 'driftless/cli/base'
require 'driftless/cli/params'
require 'driftless/cli/table'
require 'driftless/json_document'
require 'driftless/params_schema'
require 'driftless/params_schema/compare'

module Driftless
  module CLI
    class Params
      # `driftless params compare`
      #
      # The repo differences as lines, then one row per class or param
      # difference; exit 1 when the two schemas differ.
      class Compare < Base
        include Table

        register_command name: 'compare', subcommand_of: Params
        positional '<from.json>', '<to.json>'
        desc 'Show what changed between two recorded schemas'

        COLUMNS = %w[change class param detail].freeze

        def execute(argv)
          fatal!('params compare takes two schema files', help: true) unless argv.size == 2
          from, to = argv.map do |path|
            ::Driftless::ParamsSchema.read(File.expand_path(path))
          rescue ::Driftless::JsonDocument::Error => e
            fatal!("params compare: #{e.message}", 3)
          end

          repo_lines = ::Driftless::ParamsSchema::Compare.repo_changes(from, to)
          changes    = ::Driftless::ParamsSchema::Compare.class_changes(from, to)
          repo_lines.each { |line| puts "repo: #{line}" }
          puts '' if repo_lines.any? && changes.any?
          print_table(COLUMNS, changes.map { |c| [c.kind, c.class_name, c.param.to_s, c.detail] }) if changes.any?
          puts 'no differences' if repo_lines.empty? && changes.empty?
          exit((repo_lines.empty? && changes.empty?) ? 0 : 1)
        end

        protected

        def configure_parser(o)
          o.separator ''
          o.separator 'Exits 1 when the schemas differ.'
        end
      end
    end
  end
end
