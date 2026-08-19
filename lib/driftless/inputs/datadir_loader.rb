require 'psych'
require 'set'

require 'driftless/finding'
require 'driftless/models/hiera_data_file_info'

module Driftless
  module Inputs
    class DatadirLoader
      SUPPORTED_BACKENDS = [:yaml_data].freeze
      YAML_EXTENSIONS    = %w[.yaml].freeze

      def self.load(tiers)
        new(tiers).load
      end

      def initialize(tiers)
        @tiers = tiers
      end

      def load
        files = Set.new
        @tiers.each do |tier|
          next unless SUPPORTED_BACKENDS.include?(tier.backend)
          YAML_EXTENSIONS.each do |ext|
            files.merge(Dir[File.join(tier.datadir, '**', "*#{ext}")])
          end
        end

        data_files = []
        findings   = []
        files.sort.each do |path|
          df, errs = load_file(path)
          data_files << df if df
          findings.concat(errs)
        end
        [data_files, findings]
      end

      private

      def load_file(path)
        source = File.read(path)
        stream = Psych.parse_stream(source, filename: path)
        # Prime the source cache — we've already read the file to extract keys,
        # so subsequent detectors that need df.source pay zero I/O cost.
        info = HieraDataFileInfo.new(path: path, top_level_keys: extract_top_level_keys(stream), source: source)
        [info, []]
      rescue Psych::SyntaxError, StandardError => e
        [nil, [yaml_error_finding(path, e)]]
      end

      def extract_top_level_keys(stream)
        keys = {}
        stream.children.each do |doc|
          root = doc.root
          next unless root.is_a?(Psych::Nodes::Mapping)
          root.children.each_slice(2) do |key_node, _value_node|
            next unless key_node.is_a?(Psych::Nodes::Scalar)
            keys[key_node.value] = key_node.start_line + 1
          end
        end
        keys
      end

      def yaml_error_finding(path, err)
        Finding.new(
          key:     'data:yaml-parse-error',
          path:    path,
          line:    err.respond_to?(:line) ? err.line : nil,
          message: "YAML parse error: #{err.message}",
          meta:    {},
        )
      end
    end
  end
end
