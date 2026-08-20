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
  #   @return [String, nil] Which collector's file this node was taken from,
  #     parsed from `<collector>--<timestamp>` in the filename. When several
  #     collectors report the same certname only the winner's name survives,
  #     so this names the source of the data kept, not every source that saw
  #     the node. nil for nodes not built from a report file.
  Node = Struct.new(
    :certname, :environment, :facts, :trusted, :collector,
    keyword_init: true,
  ) do
    def initialize(certname:, environment: nil, facts: {}, trusted: {}, collector: nil)
      super
    end

    include Puppet::Pops::Lookup::SubLookup

    def fact(path)
      segments = split_key(path.to_s)
      case segments.first
      when 'facts'
        dig_hash(facts, segments.drop(1))
      when 'trusted'
        dig_hash(trusted, segments.drop(1))
      else
        dig_hash(facts, segments) || dig_hash(trusted, segments)
      end
    end

    private

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
