require 'driftless/detectors'
require 'driftless/finding'

module Driftless
  module Detectors
    class Base
      class << self
        def key(k = nil)
          k.nil? ? @key : (@key = k)
        end

        def about(text = nil)
          text.nil? ? @about : (@about = text)
        end

        def requires_reports(*names)
          if names.empty?
            @requires_reports ||= []
          else
            @requires_reports = names.flatten.map(&:to_s)
          end
        end

        def inherited(subclass)
          super
          Detectors.register(subclass)
        end
      end

      attr_reader :corpus

      def initialize(corpus)
        @corpus = corpus
      end

      def call
        raise NotImplementedError, "#{self.class} must implement #call"
      end

      protected

      def build_finding(message:, path: nil, line: nil, meta: {})
        Finding.new(
          key: self.class.key,
          path: path,
          line: line,
          message: message,
          meta: meta,
        )
      end

      def meta_finding(key:, message:, path: nil, line: nil, meta: {})
        Finding.new(key: key, path: path, line: line, message: message, meta: meta)
      end

      def skip_meta_finding(reason:)
        Finding.new(
          key: "skipped:#{self.class.key}",
          path: nil,
          line: nil,
          message: "detector skipped: #{reason}",
          meta: {},
        )
      end
    end
  end
end
