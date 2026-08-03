module Driftless
  module Outputs
    module TextWriter
      module_function

      def write(findings, io)
        if findings.empty?
          io.puts 'no findings'
          return
        end

        grouped = findings.group_by(&:key).sort_by { |k, _| k }

        grouped.each_with_index do |(key, group), i|
          io.puts if i > 0
          io.puts "#{key} (#{group.length} #{group.length == 1 ? 'finding' : 'findings'})"
          group.sort_by { |f| [f.path.to_s, f.line || 0] }.each do |f|
            io.puts "  #{format_location(f)}  #{f.message}"
          end
        end
      end

      def format_location(f)
        return '-' unless f.path
        return f.path unless f.line
        "#{f.path}:#{f.line}"
      end
    end
  end
end
