require 'io/console'

require 'driftless/ansi'

module Driftless
  module CLI
    # Plain-text table output, columns left-aligned. Cells may carry ANSI
    # colour; widths count the visible characters. A table wider than the
    # terminal has its widest columns narrowed and their long cells wrapped
    # onto continuation lines, so nothing is cut; `--width` sets the limit
    # by hand (0 for none), and output that is not a terminal has none.
    module Table
      ANSI  = /\e\[[0-9;]*m/.freeze
      RESET = "\e[0m".freeze

      # Columns are not narrowed below this.
      FLOOR = 16

      # Where a wrapped cell prefers to break, in order.
      BREAKS = ['; ', ', ', ' '].freeze

      # Prints a header, a rule, and one line per row.
      #
      # @param columns [Array<String>] header cells
      # @param rows [Array<Array<String>>] one cell per column
      def print_table(columns, rows)
        if rows.empty?
          puts '(nothing matches)'
          return
        end
        rows   = rows.map { |r| r.map { |c| clean(c) } }
        widths = columns.each_index.map { |i| ([columns[i]] + rows.map { |r| r[i] }).map { |c| visible(c).length }.max }
        widths = fit(widths, table_width)
        puts align(columns, widths)
        puts widths.map { |w| '-' * w }.join('-+-')
        rows.each { |r| wrap_row(r, widths).each { |line| puts align(line, widths) } }
      end

      # The text coloured when stdout takes colour, else as given.
      def paint(text, *styles)
        ::Driftless::Ansi.enabled?($stdout) ? ::Driftless::Ansi.wrap(text, *styles) : text.to_s
      end

      private

      # @return [Integer, nil] the width to fit, nil for no limit
      def table_width
        given = defined?(@options) && @options && @options[:width]
        return given.zero? ? nil : given if given

        return nil unless $stdout.respond_to?(:tty?) && $stdout.tty?

        IO.console&.winsize&.last
      rescue StandardError
        nil
      end

      # Column widths that fit the limit: the widest column is narrowed
      # towards the next widest, and so on, never below the floor.
      def fit(widths, limit)
        return widths if limit.nil?

        widths = widths.dup
        overhead = 3 * (widths.size - 1)
        while widths.sum + overhead > limit
          i = widths.each_with_index.max_by { |w, _| w }.last
          others = widths.each_with_index.reject { |_, j| j == i }.map(&:first).max || 0
          # down to the next widest, or by the excess when that is less;
          # when the next widest is as wide, this one goes first
          stop   = (others < widths[i]) ? others : FLOOR
          target = [FLOOR, [stop, widths[i] - (widths.sum + overhead - limit)].max].max
          break if target >= widths[i]

          widths[i] = target
        end
        widths
      end

      # Whitespace runs become one space, so a newline never breaks a row.
      def clean(cell)
        cell.to_s.gsub(/\s+/, ' ').strip
      end

      def visible(cell)
        cell.to_s.gsub(ANSI, '')
      end

      # The row as lines: cells wider than their column wrap, the others
      # sit on the first line with blanks below.
      def wrap_row(cells, widths)
        wrapped = cells.each_with_index.map { |c, i| wrap_cell(c, widths[i]) }
        depth   = wrapped.map(&:size).max
        Array.new(depth) { |n| wrapped.map { |lines| lines[n] || '' } }
      end

      # @return [Array<String>] the cell's lines, colour kept across them
      def wrap_cell(cell, width)
        return [cell] if visible(cell).length <= width

        lines = []
        rest  = cell
        while visible(rest).length > width
          head, rest = split_visible(rest, width)
          lines << head
        end
        lines << rest
      end

      # Splits at the last preferred break within the width, else at the
      # width; the break's punctuation stays at the end of the first part.
      # Escape codes count nothing; an open colour is closed at the end of
      # the first part and reopened at the start of the second.
      def split_visible(text, width)
        plain = visible(text)
        token = BREAKS.find { |b| i = plain[0, width + 1].rindex(b)
 i&.positive? && i + b.length <= width + 1 }
        at = token && plain[0, width + 1].rindex(token)
        head_end, tail_start = token ? [at + token.length - 1, at + token.length] : [width, width]
        head  = text[0, raw_index(text, head_end)]
        tail  = text[raw_index(text, tail_start)..].to_s
        open  = active_codes(head)
        head += RESET unless open.empty?
        [head, open + tail]
      end

      # The raw index of the visible character `n`.
      def raw_index(text, n)
        seen = 0
        i = 0
        while i < text.length
          if (m = text.match(ANSI, i)) && m.begin(0) == i
            i = m.end(0)
            next
          end
          return i if seen == n

          seen += 1
          i += 1
        end
        text.length
      end

      # The escape codes in force at the end of the text, as one string.
      def active_codes(text)
        codes = []
        text.scan(ANSI) { |c| (c == RESET) ? codes.clear : codes << c }
        codes.join
      end

      def align(cells, widths)
        cells.each_with_index.map { |c, i| c.to_s + (' ' * [widths[i] - visible(c).length, 0].max) }.join(' | ').rstrip
      end
    end
  end
end
