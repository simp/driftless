require 'yaml'

require 'driftless/detectors/input_registrations'
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
            Detectors::HierarchyHieraYamlMissing,
            "no hiera.yaml at #{@hiera_yaml}",
          )
          return [tiers, findings]
        end

        source = File.read(@hiera_yaml)

        doc =
          begin
            YAML.safe_load(source, permitted_classes: [Symbol])
          rescue Psych::SyntaxError => e
            findings << finding(
              Detectors::DataYamlParseError,
              "hiera.yaml parse error: #{e.message}",
            )
            return [tiers, findings]
          end

        unless doc.is_a?(Hash) && doc['version'] == 5
          findings << finding(
            Detectors::HierarchyUnsupportedVersion,
            'hiera.yaml must be a Hash with version: 5',
          )
          return [tiers, findings]
        end

        defaults        = doc['defaults'] || {}
        default_datadir = defaults['datadir']   || 'data'
        default_backend = defaults['data_hash'] || 'yaml_data'

        entry_lines = hierarchy_entry_lines(source)

        Array(doc['hierarchy']).each_with_index do |entry, i|
          next unless entry.is_a?(Hash)

          line     = entry_lines[i]
          name     = entry['name'] || '(unnamed)'
          declared = entry['datadir'] || default_datadir
          datadir  = File.expand_path(declared, @repo_dir)

          if entry.key?('lookup_key') || entry.key?('data_dig')
            findings << finding(
              Detectors::HierarchyUnscannableByDriftlessBackend,
              "tier #{name.inspect} uses a lookup_key/data_dig backend " \
              '(driftless currently only scans data_hash tiers with a datadir)',
              line: line,
            )
            next
          end

          backend = entry['data_hash'] || default_backend
          unless SUPPORTED_DATA_HASH_BACKENDS.include?(backend)
            findings << finding(
              Detectors::HierarchyUnscannableBackend,
              "tier #{name.inspect} uses data_hash: #{backend.inspect} (currently unscannable by driftless)",
              line: line,
            )
            next
          end

          templates, multi, locator = extract_templates(entry)
          if templates.nil?
            findings << finding(
              Detectors::HierarchyTierMissingPath,
              "tier #{name.inspect} has neither path: nor paths:",
              line: line,
            )
            next
          end

          # Both reported as hiera.yaml spells the datadir, which is how a
          # reader will recognize it. Either way the tier is declared correctly
          # and stays in the hierarchy; only its data files go unread.
          if declared.to_s.match?(INTERPOLATION_RE)
            # Hiera renders the datadir before resolving paths against it, so
            # the token is legitimate and the literal string is never a
            # directory. driftless does not render it.
            findings << finding(
              Detectors::HierarchyInterpolatedDatadir,
              "tier #{name.inspect} interpolates its datadir #{declared.inspect} " \
              '(currently unscannable by driftless)',
              line: line,
            )
          elsif !File.directory?(datadir)
            findings << finding(
              Detectors::HierarchyMissingDatadir,
              "tier #{name.inspect} has datadir #{declared.inspect}, which is not a directory",
              line: line,
            )
          end

          tiers << HieraTier.new(
            name:               name,
            datadir:            datadir,
            backend:            backend.to_sym,
            path_templates:     templates,
            interpolation_vars: templates.flat_map { |t| interpolation_vars(t) }.uniq,
            multi_path:         multi,
            locator:            locator,
            source_line:        line,
          )
        end

        [tiers, findings]
      end

      private

      # 1-indexed line numbers per hierarchy: entry, positionally aligned with
      # Array(doc['hierarchy']). Any parse or shape mismatch → [], in which case
      # every tier's source_line stays nil (nil-safe downstream).
      def hierarchy_entry_lines(source)
        ast = Psych.parse(source)
        return [] unless ast
        root = ast.root
        return [] unless root.is_a?(Psych::Nodes::Mapping)

        root.children.each_slice(2) do |key, value|
          next unless key.is_a?(Psych::Nodes::Scalar) && key.value == 'hierarchy'
          return [] unless value.is_a?(Psych::Nodes::Sequence)
          return value.children.map { |entry| entry.start_line + 1 }
        end
        []
      rescue Psych::SyntaxError
        []
      end

      # Returns [templates, multi_path, locator]. Hiera permits exactly one
      # location key per tier and checks them in this order, so the first one
      # present is the one it would use.
      def extract_templates(entry)
        if entry.key?('path')
          [[String(entry['path'])], false, :path]
        elsif entry.key?('paths')
          [Array(entry['paths']).map(&:to_s), true, :path]
        elsif entry.key?('glob')
          [[String(entry['glob'])], false, :glob]
        elsif entry.key?('globs')
          [Array(entry['globs']).map(&:to_s), true, :glob]
        else
          [nil, nil, nil]
        end
      end

      def interpolation_vars(template)
        template.to_s.scan(INTERPOLATION_RE).map { |m| m[0].strip }
      end

      # Every finding here anchors to hiera.yaml; the registration supplies
      # the key and how the finding is graded.
      def finding(registration, message, line: nil)
        registration.finding(path: @hiera_yaml, line: line, message: message)
      end
    end
  end
end
