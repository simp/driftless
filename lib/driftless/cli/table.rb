module Driftless
  module CLI
    # Plain-text table output for the `list` subcommands.
    module Table
      # Prints a header, a rule, and one line per row, columns left-aligned.
      #
      # @param columns [Array<String>] header cells
      # @param rows [Array<Array<String>>] one cell per column
      def print_table(columns, rows)
        if rows.empty?
          puts '(nothing matches)'
          return
        end
        widths = columns.each_index.map { |i| ([columns[i]] + rows.map { |r| r[i] }).map(&:length).max }
        puts align(columns, widths)
        puts widths.map { |w| '-' * w }.join('-+-')
        rows.each { |r| puts align(r, widths) }
      end

      private

      def align(cells, widths)
        cells.each_with_index.map { |c, i| c.ljust(widths[i]) }.join(' | ').rstrip
      end
    end
  end
end
