require 'json'

module Pupgrade
  module Compile
    # The compile record `compile` writes beside each catalog
    # (`compile.json`: the probes' findings and the compile's outcome), and
    # the check every reader makes before trusting one: that it is a
    # compile record, and of the schema this pupgrade reads. A record
    # written by another pupgrade is refused with a message saying which
    # side is newer, since `solve` and `impact` read these across releases.
    module ProbeRecord
      DOCUMENT       = 'compile'.freeze
      SCHEMA_VERSION = 3
      FILENAME       = 'compile.json'.freeze
      # The record's name before schema 3.
      OLD_FILENAME   = 'probes.json'.freeze

      class Error < StandardError; end

      module_function

      # @param dir [String] a `compile` output directory
      # @return [Array<String>] every node's record, sorted
      # @raise [Error] when there is none; naming an older pupgrade when its
      #   records are there
      def paths(dir)
        found = Dir.glob(File.join(dir, '*', FILENAME)).sort
        return found unless found.empty?

        old = Dir.glob(File.join(dir, '*', OLD_FILENAME)).first
        raise Error, "#{dir}: #{File.basename(File.dirname(old))}/#{OLD_FILENAME} was written by an older pupgrade; compile again with this pupgrade" if old

        raise Error, "#{dir}: no <certname>/#{FILENAME} under it"
      end

      # @param path [String] a compile.json
      # @return [Hash] the record
      # @raise [Error] when the file is not a compile record of this schema
      def read(path)
        data = JSON.parse(File.read(path))
        raise Error, "#{path}: not a compile record (document #{data['document'].inspect})" unless data.is_a?(Hash) && data['document'] == DOCUMENT

        version = data['schema_version']
        unless version == SCHEMA_VERSION
          side = (version.to_i > SCHEMA_VERSION) ? 'newer than this pupgrade reads' : 'older than this pupgrade reads'
          raise Error, "#{path}: compile record schema #{version.inspect} is #{side} (#{SCHEMA_VERSION}); compile again with this pupgrade"
        end
        data
      rescue JSON::ParserError => e
        raise Error, "#{path}: #{e.message}"
      rescue Errno::ENOENT
        old = File.join(File.dirname(path), OLD_FILENAME)
        raise Error, "#{old} was written by an older pupgrade; compile again with this pupgrade" if File.file?(old)

        raise Error, "#{path}: no such file"
      end
    end
  end
end
