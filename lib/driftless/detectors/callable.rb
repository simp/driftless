require 'driftless/detectors/registration'
require 'driftless/finding'

module Driftless
  module Detectors
    # A registration that goes looking for its own findings: {Scan} builds one
    # per scan against the corpus and calls it.
    class Callable < Registration
      class << self
        def requires_reports(*names)
          if names.empty?
            @requires_reports ||= []
          else
            @requires_reports = names.flatten.map(&:to_s)
          end
        end

        def callable?
          true
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

      def meta_finding(key:, message:, path: nil, line: nil, meta: {},
                       severity: nil, quality: nil)
        Finding.new(
          key:      key,
          path:     path,
          line:     line,
          message:  message,
          meta:     meta,
          severity: severity || self.class.severity,
          quality:  quality  || self.class.quality,
        )
      end

      def skip_meta_finding(reason:)
        Finding.new(
          key:      "skipped:#{self.class.key}",
          path:     nil,
          line:     nil,
          message:  "detector skipped: #{reason}",
          meta:     {},
          severity: :note,
          quality:  nil,
        )
      end
    end
  end
end
