require 'json'

module Driftless
  module Outputs
    module JsonWriter
      module_function

      # color: and tabularize: are accepted so every writer shares one signature;
      # JSON has no rendering options.
      # rubocop:disable Lint/UnusedMethodArgument -- intentional; see comment
      def write(findings, io, color: nil, tabularize: nil)
        sorted = findings.sort_by { |f| [f.key, f.path.to_s, f.line || 0] }
        io.puts '['
        sorted.each_with_index do |f, i|
          separator = (i < sorted.length - 1) ? ',' : ''
          io.puts "  #{JSON.generate(finding_to_h(f))}#{separator}"
        end
        io.puts ']'
      end
      # rubocop:enable Lint/UnusedMethodArgument

      # The JSON document carries no summary; consumers count the array.
      # Accepted so every writer shares one signature.
      def write_summary(findings, io, color: nil); end

      def finding_to_h(f)
        {
          key:      f.key,
          severity: f.severity,
          quality:  f.quality,
          path:     f.path,
          line:     f.line,
          message:  f.message,
          meta:     f.meta || {},
        }
      end
    end
  end
end
