require 'json'

module Driftless
  module Inputs
    # Reads a module's `metadata.json`: its Forge name and version, what it
    # depends on, and the Puppet versions and operating systems it declares
    # support for.
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
      #   @return [Hash{String => String, nil}] the `requirements` entries as
      #     name => version_requirement; nil when the entry gives none
      # @!attribute [r] dependencies
      #   @return [Hash{String => String, nil}] the `dependencies` entries as
      #     name => version_requirement; nil when the entry gives none
      # @!attribute [r] operatingsystem_support
      #   @return [Hash{String => Array<String>}] the `operatingsystem_support`
      #     entries as operatingsystem => operatingsystemrelease; empty when
      #     the entry names no releases
      # @!attribute [r] error
      #   @return [String, nil] why the file could not be read as a mapping;
      #     the other fields are then empty
      Result = Data.define(:exists, :name, :version, :requirements, :dependencies, :operatingsystem_support, :error) do
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
        return absent unless File.file?(path)

        parse(File.read(path), path: path)
      end

      # @param text [String] a metadata.json's contents
      # @param path [String] where it came from, named in the error
      # @return [Result]
      def self.parse(text, path:)
        data = JSON.parse(text)
        raise JSON::ParserError, 'not a mapping' unless data.is_a?(Hash)

        Result.new(exists: true, name: data['name']&.to_s, version: data['version']&.to_s,
                   requirements: named_requirements(data['requirements']),
                   dependencies: named_requirements(data['dependencies']),
                   operatingsystem_support: os_support(data['operatingsystem_support']), error: nil)
      rescue JSON::ParserError => e
        absent.with(exists: true, error: "#{path}: #{e.message.lines.first.to_s.strip}")
      end

      # @return [Result] for a module with no metadata.json
      def self.absent
        Result.new(exists: false, name: nil, version: nil, requirements: {}, dependencies: {},
                   operatingsystem_support: {}, error: nil)
      end

      # @param list [Array<Hash>, nil] `requirements` or `dependencies` as written
      # @return [Hash{String => String, nil}] name => version_requirement
      def self.named_requirements(list)
        Array(list).each_with_object({}) do |r, h|
          next unless r.is_a?(Hash) && r['name']

          h[r['name'].to_s] = r['version_requirement']&.to_s
        end
      end

      # @param list [Array<Hash>, nil] `operatingsystem_support` as written
      # @return [Hash{String => Array<String>}] operatingsystem => releases
      def self.os_support(list)
        Array(list).each_with_object({}) do |r, h|
          next unless r.is_a?(Hash) && r['operatingsystem']

          h[r['operatingsystem'].to_s] = Array(r['operatingsystemrelease']).map(&:to_s)
        end
      end
    end
  end
end
