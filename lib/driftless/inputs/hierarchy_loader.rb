require 'yaml'

require 'driftless/finding'
require 'driftless/models/hiera_tier'

module Driftless
  module Inputs
    class HierarchyLoader
      SUPPORTED_DATA_HASH_BACKENDS = %w[yaml_data json_data hocon_data].freeze
      INTERPOLATION_RE = /%\{([^{}]+)\}/.freeze

      def self.load(repo_dir)
        new(repo_dir).load
      end

      def initialize(repo_dir)
        @repo_dir   = repo_dir
        @hiera_yaml = File.join(repo_dir, 'hiera.yaml')
      end

      def load
        tiers    = []
        findings = []

        unless File.file?(@hiera_yaml)
          findings << finding(
            'hierarchy:hiera-yaml-missing',
            "no hiera.yaml at #{@hiera_yaml}",
          )
          return [tiers, findings]
        end

        doc =
          begin
            YAML.safe_load(File.read(@hiera_yaml), permitted_classes: [Symbol])
          rescue Psych::SyntaxError => e
            findings << finding(
              'data:yaml-parse-error',
              "hiera.yaml parse error: #{e.message}",
            )
            return [tiers, findings]
          end

        unless doc.is_a?(Hash) && doc['version'] == 5
          findings << finding(
            'hierarchy:unsupported-version',
            'hiera.yaml must be a Hash with version: 5',
          )
          return [tiers, findings]
        end

        defaults        = doc['defaults'] || {}
        default_datadir = defaults['datadir']   || 'data'
        default_backend = defaults['data_hash'] || 'yaml_data'

        Array(doc['hierarchy']).each do |entry|
          next unless entry.is_a?(Hash)

          name    = entry['name'] || '(unnamed)'
          datadir = File.expand_path(entry['datadir'] || default_datadir, @repo_dir)

          if entry.key?('lookup_key') || entry.key?('data_dig')
            findings << finding(
              'hierarchy:unsupported-backend',
              "tier #{name.inspect} uses a lookup_key/data_dig backend " \
              '(only data_hash tiers with a datadir are currently supported)',
            )
            next
          end

          backend = entry['data_hash'] || default_backend
          unless SUPPORTED_DATA_HASH_BACKENDS.include?(backend)
            findings << finding(
              'hierarchy:unsupported-backend',
              "tier #{name.inspect} uses unsupported data_hash: #{backend.inspect}",
            )
            next
          end

          templates, multi = extract_templates(entry)
          if templates.nil?
            findings << finding(
              'hierarchy:tier-missing-path',
              "tier #{name.inspect} has neither path: nor paths:",
            )
            next
          end

          tiers << HieraTier.new(
            name:               name,
            datadir:            datadir,
            backend:            backend.to_sym,
            path_templates:     templates,
            interpolation_vars: templates.flat_map { |t| interpolation_vars(t) }.uniq,
            multi_path:         multi,
          )
        end

        [tiers, findings]
      end

      private

      def extract_templates(entry)
        if entry.key?('path')
          [[String(entry['path'])], false]
        elsif entry.key?('paths')
          [Array(entry['paths']).map(&:to_s), true]
        else
          [nil, nil]
        end
      end

      def interpolation_vars(template)
        template.to_s.scan(INTERPOLATION_RE).map { |m| m[0].strip }
      end

      def finding(key, message)
        Finding.new(key: key, path: @hiera_yaml, line: nil, message: message, meta: {})
      end
    end
  end
end
