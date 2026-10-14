require 'json'

module Driftless
  module Inputs
    # Reads a module's `metadata.json`: its Forge name, version, and the
    # Puppet versions it declares support for.
    class ModuleMetadata
      FILENAME = 'metadata.json'.freeze

      # The `requirements` names that mean the Puppet runtime; a module
      # declares either.
      PUPPET_REQUIREMENT_NAMES = %w[puppet openvox].freeze

      # @!attribute [r] exists
      #   @return [Boolean] whether the file was there
      # @!attribute [r] name
      #   @return [String, nil] the `name` key, e.g. "puppetlabs-stdlib"
      # @!attribute [r] version
      #   @return [String, nil] the `version` key
      # @!attribute [r] requirements
      #   @return [Hash{String => String}] the `requirements` entries as
      #     name => version_requirement
      # @!attribute [r] error
      #   @return [String, nil] why the file could not be read as a mapping;
      #     the other fields are then empty
      Result = Data.define(:exists, :name, :version, :requirements, :error) do
        def exists?
          exists
        end

        # @return [String, nil] the puppet or openvox version requirement;
        #   both, joined, when they differ
        def puppet_requirement
          values = requirements.values_at(*PUPPET_REQUIREMENT_NAMES).compact.uniq
          values.empty? ? nil : values.join(' / ')
        end
      end

      # @param module_dir [String] the module's directory
      # @return [Result]
      def self.load(module_dir)
        path = File.join(module_dir, FILENAME)
        return Result.new(exists: false, name: nil, version: nil, requirements: {}, error: nil) unless File.file?(path)

        data = JSON.parse(File.read(path))
        raise JSON::ParserError, 'not a mapping' unless data.is_a?(Hash)

        requirements = Array(data['requirements']).each_with_object({}) do |r, h|
          h[r['name'].to_s] = r['version_requirement'].to_s if r.is_a?(Hash) && r['name']
        end
        Result.new(exists: true, name: data['name']&.to_s, version: data['version']&.to_s,
                   requirements: requirements, error: nil)
      rescue JSON::ParserError => e
        Result.new(exists: true, name: nil, version: nil, requirements: {},
                   error: "#{path}: #{e.message.lines.first.to_s.strip}")
      end
    end
  end
end
