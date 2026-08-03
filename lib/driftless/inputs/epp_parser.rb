require 'puppet'

require 'driftless/finding'

module Driftless
  module Inputs
    class EppParser
      def self.parse(path)
        new(path).parse
      end

      def self.parser
        @parser ||= Puppet::Pops::Parser::EppParser.new
      end

      def initialize(path)
        @path = path
      end

      def parse
        source  = File.read(@path)
        factory = self.class.parser.parse_string(source, @path)
        [factory.model, []]
      rescue Errno::ENOENT => e
        [nil, [parse_error_finding(nil, "template not readable: #{e.message}")]]
      rescue StandardError => e
        line = e.respond_to?(:line) ? e.line : nil
        [nil, [parse_error_finding(line, "EPP parse error: #{e.message}")]]
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
