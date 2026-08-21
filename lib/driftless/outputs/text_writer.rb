require 'driftless/ansi'

module Driftless
  module Outputs
    module TextWriter
      SEVERITY_STYLES = {
        error:   [:red, :bold],
        warning: [:yellow],
        note:    [:cyan],
      }.freeze

      # Quality is a categorical tag, not a severity axis — one color for all.
      QUALITY_STYLES = {
        stale:      [:cyan],
        wrong:      [:cyan],
        weird:      [:cyan],
        impossible: [:cyan],
      }.freeze

      PATH_STYLES    = [:white].freeze
      LINE_STYLES    = [:blue].freeze
      MESSAGE_STYLES = [:cyan].freeze

      # Column widths sized to the longest known label. Pad the RAW string
      # then wrap — ljust on an ANSI-wrapped string miscounts escape bytes.
      SEVERITY_WIDTH = 7   # "warning"
      QUALITY_WIDTH  = 10  # "impossible"

      module_function

      # `color:` nil means auto — on if io.tty?. Callers may force true/false
      # to reflect --color / --no-color or NO_COLOR.
      # `tabularize:` pads each group's locations to a common width so the
      # messages line up.
      def write(findings, io, color: nil, tabularize: true)
        color = io.respond_to?(:tty?) && io.tty? if color.nil?
        style = ->(str, *s) { color ? Ansi.wrap(str, *s) : str }

        if findings.empty?
          io.puts 'no findings'
          return
        end

        grouped = findings.group_by(&:key).sort_by { |k, _| k }

        grouped.each_with_index do |(key, group), i|
          io.puts if i > 0
          io.puts group_header(key, group, style)
          items = group.sort_by { |f| [f.path.to_s, f.line || 0] }
          width = tabularize ? items.map { |f| raw_location(f).length }.max : nil
          items.each do |f|
            pad = width ? ' ' * (width - raw_location(f).length) : ''
            io.puts "  #{format_location(f, style)}#{pad}  #{style.call(f.message, *MESSAGE_STYLES)}"
          end
        end
      end

      # Detector-class contract: severity/quality are declared per-key, so
      # all findings in a group share both. Pull from the first.
      def group_header(key, group, style)
        f     = group.first
        sev   = f.severity.to_s.ljust(SEVERITY_WIDTH)
        qual  = f.quality.to_s.ljust(QUALITY_WIDTH)
        count = group.length
        noun  = (count == 1) ? 'finding' : 'findings'

        "#{style.call(sev, *SEVERITY_STYLES.fetch(f.severity, []))} " \
          "#{style.call(qual, *QUALITY_STYLES.fetch(f.quality, []))}  " \
          "#{style.call(key, :bold)} (#{count} #{noun})"
      end

      def format_location(f, style)
        return '-' unless f.path
        return style.call(f.path, *PATH_STYLES) unless f.line
        "#{style.call(f.path, *PATH_STYLES)}:#{style.call(f.line, *LINE_STYLES)}"
      end

      # Width source for tabularize — format_location's return may carry ANSI
      # escapes, whose bytes don't occupy columns.
      def raw_location(f)
        return '-' unless f.path
        return f.path.to_s unless f.line
        "#{f.path}:#{f.line}"
      end
    end
  end
end
