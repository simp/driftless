require 'fileutils'
require 'json'

module Driftless
  # Reading and writing the JSON documents commands hand each other (design
  # notes §7): `scan` writes one, `report` will write one, `site` reads them
  # and writes the build data. Every document names its kind and schema
  # version in its first two keys, and {read} refuses anything else.
  module JsonDocument
    # A document that cannot be used: missing, not JSON, or not the kind and
    # version the caller renders.
    class Error < StandardError; end

    module_function

    # Writes data as pretty-printed JSON, creating parent directories.
    # @return [String] path
    def write(data, path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(data)}\n")
      path
    end

    # @param document [String] the `document` value expected, e.g. "scan"
    # @param schema_version [Integer] the `schema_version` expected
    # @raise [Error] when the file is unusable
    def read(path, document:, schema_version:)
      data = JSON.parse(File.read(path))
      raise Error, "#{path}: not a driftless document" unless data.is_a?(Hash)

      kind = data['document']
      raise Error, "#{path}: is a #{kind.inspect} document, expected #{document.inspect}" unless kind == document

      version = data['schema_version']
      unless version == schema_version
        raise Error, "#{path}: #{document} schema_version #{version.inspect}, expected #{schema_version}"
      end
      data
    rescue SystemCallError => e
      # "No such file or directory @ rb_sysopen - path" → "path: No such file or directory"
      raise Error, "#{path}: #{e.message.sub(/ @ .*\z/, '')}"
    rescue JSON::ParserError => e
      raise Error, "#{path}: not valid JSON (#{e.message.lines.first&.strip})"
    end
  end
end
