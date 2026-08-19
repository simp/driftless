module Driftless
  module Detectors
    class << self
      def register(klass)
        @registry ||= []
        @registry << klass unless @registry.include?(klass)
      end

      def registry
        (@registry ||= []).dup.freeze
      end

      def find(key)
        registry.find { |k| k.key == key }
      end

      # Union of `requires_reports` across every enabled detector class.
      # Instantiating with `nil` corpus is safe — option(:enabled) only touches
      # Driftless.config. Shared by Import::Cleanup (A+ rule) and Scan
      # (coverage check).
      def expected_reports
        registry.each_with_object([]) { |klass, acc|
          next unless klass.new(nil).option(:enabled)
          klass.requires_reports.each { |r| acc << r.to_s }
        }.uniq.sort
      end
    end
  end
end
