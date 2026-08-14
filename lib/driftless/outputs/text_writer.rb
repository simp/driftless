require 'driftless/ansi'

module Driftless
  module Outputs
    module TextWriter
      SEVERITY_STYLES = {
        error:   %i[red bold],
        warning: %i[yellow],
        note:    %i[cyan],
      }.freeze

      # Column widths sized to the longest known label. Pad the RAW string
      # then wrap — ljust on an ANSI-wrapped string miscounts escape bytes.
      SEVERITY_WIDTH = 7   # "warning"
      QUALITY_WIDTH  = 10  # "impossible"

      module_function

      # `color:` nil means auto — on iff io.tty?. Callers may force true/false
      # to reflect --color / --no-color or NO_COLOR.
      def write(findings, io, color: nil)
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
          group.sort_by { |f| [f.path.to_s, f.line || 0] }.each do |f|
            io.puts "  #{format_location(f)}  #{f.message}"
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
        noun  = count == 1 ? 'finding' : 'findings'

        "#{style.call(sev, *SEVERITY_STYLES.fetch(f.severity, []))} " \
          "#{qual}  " \
          "#{style.call(key, :bold)} (#{count} #{noun})"
      end

      def format_location(f)
        return '-' unless f.path
        return f.path unless f.line
        "#{f.path}:#{f.line}"
      end
    end
  end
end
