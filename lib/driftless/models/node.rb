module Puppet; end unless defined?(Puppet)
require 'puppet/pops/lookup/sub_lookup'

module Driftless
  # One active node as reported by PuppetDB, merged across collectors.
  #
  # @!attribute [r] certname
  #   @return [String] The node's certname; unique within a merged report set.
  # @!attribute [r] environment
  #   @return [String, nil] catalog_environment when present, else environment.
  #     nil when the report carried neither.
  # @!attribute [r] facts
  #   @return [Hash] Structured facts, as reported.
  # @!attribute [r] trusted
  #   @return [Hash] Trusted facts, as reported.
  # @!attribute [r] collector
  #   @return [String, nil] Which collector reported this node, parsed from
  #     `<collector>--<timestamp>` in the filename. nil for nodes not built
  #     from a report file.
  Node = Struct.new(
    :certname, :environment, :facts, :trusted, :collector,
    keyword_init: true,
  ) do
    def initialize(certname:, environment: nil, facts: {}, trusted: {}, collector: nil)
      super
    end

    include Puppet::Pops::Lookup::SubLookup

    # Returns hash of known fact paths' data structures (shared by every Node)
    def self.memoized_split_fact_paths
      # Hash mapping: fact_path => [namespace, split_fact_path]
      #   namespace: :facts, :trusted, or :unprefixed, as the key declared it
      #   split_fact_path: structured.fact.dot.path, as Arrays
      @memoized_split_fact_paths ||= {}
    end

    def fact(path)
      key = path.to_s
      root, segments = self.class.memoized_split_fact_paths[key] ||= parse_key(key)
      dig_hash((root == :trusted) ? trusted : facts, segments)
    end

    private

    def parse_key(key)
      segments = split_key(key)
      case segments.first
      when 'facts'   then [:facts,      segments.drop(1)]
      when 'trusted' then [:trusted,    segments.drop(1)]
      # Unprefixed names cannot reach $trusted: reserved, always structured.
      else                [:unprefixed, segments]
      end
    end

    def dig_hash(hash, segments)
      return nil if hash.nil? || segments.empty?
      current = hash
      segments.each do |seg|
        return nil unless current.is_a?(Hash) && current.key?(seg)
        current = current[seg]
      end
      current
    end
  end
end
