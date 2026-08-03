require 'puppet'
require 'puppet/pops/lookup/sub_lookup'

module Driftless
  Node = Struct.new(
    :certname, :facts, :trusted,
    keyword_init: true,
  ) do
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
