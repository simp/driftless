require 'puppet'

require 'driftless/finding'

module Driftless
  module Inputs
    class ManifestParser
      def self.parse(path)
        new(path).parse
      end

      def self.evaluator
        @evaluator ||= Puppet::Pops::Parser::EvaluatingParser.new
      end

      def initialize(path)
        @path = path
      end

      def parse
        source  = File.read(@path)
        program = self.class.evaluator.parse_string(source, @path)
        [program, []]
      rescue Errno::ENOENT => e
        [nil, [parse_error_finding(nil, "manifest not readable: #{e.message}")]]
      rescue StandardError => e
        line = e.respond_to?(:line) ? e.line : nil
        [nil, [parse_error_finding(line, "parse error: #{e.message}")]]
      end

      private

      def parse_error_finding(line, message)
        Finding.new(
          key:     'code:parse-error',
          path:    @path,
          line:    line,
          message: message,
          meta:    {},
        )
      end
    end
  end
end
