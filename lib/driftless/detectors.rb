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
    end
  end
end
