require 'json'

module Driftless
  module Outputs
    module JsonWriter
      module_function

      def write(findings, io)
        sorted = findings.sort_by { |f| [f.key, f.path.to_s, f.line || 0] }
        io.puts '['
        sorted.each_with_index do |f, i|
          separator = (i < sorted.length - 1) ? ',' : ''
          io.puts "  #{JSON.generate(finding_to_h(f))}#{separator}"
        end
        io.puts ']'
      end

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
