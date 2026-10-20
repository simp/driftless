require 'time'

require 'driftless/config_keys'
require 'driftless/json_document'
require 'driftless/repo_data'
require 'driftless/version'

module Driftless
  # The document `params record` writes: every class on the modulepath with
  # its params, each param's type and default as written in the manifest,
  # beside the repo description. `params validate` checks a repo's Hiera
  # keys and lookup() calls against one
  module ParamsSchema
    extend ConfigKeys::DSL

    DOCUMENT       = 'params'.freeze
    SCHEMA_VERSION = 1

    # Where `params record` writes and `params validate` reads, relative to
    # the control repo, when neither is told otherwise.
    DEFAULT_FILE = 'driftless-params.json'.freeze

    config_key 'params.schema_file', type: :string, default: DEFAULT_FILE,
               about: 'Where `params record` writes and `params validate` reads, relative to the control repo'

    module_function

    # @param corpus [Corpus] the repo as {Codebase} loaded it
    # @param now [Time] stamp for `generated_at`; injectable for specs
    # @return [Hash] string-keyed, ready for JSON.generate
    def assemble(corpus:, now: Time.now)
      {
        'document'          => DOCUMENT,
        'schema_version'    => SCHEMA_VERSION,
        'generated_at'      => now.utc.iso8601,
        'driftless_version' => VERSION,
        'repo'              => RepoData.describe(corpus),
        'classes'           => classes(corpus),
      }
    end

    # Classes and defined types by name, sorted, each with its manifest
    # (repo-relative) and its params in declaration order. A param's `type`
    # and `default` are the manifest's text, null when it gives none.
    #
    # @return [Hash{String => Hash}]
    def classes(corpus)
      corpus.puppet_classes.sort.to_h do |fqname, cls|
        params = cls.params.to_h { |p| [p.name, { 'type' => text(p.type_expr), 'default' => text(p.default_expr) }] }
        [fqname, { 'file' => relative(cls.file, corpus.repo_dir), 'params' => params }]
      end
    end

    # @param expr [Puppet::Pops::Model::PopsObject, nil] a parsed expression
    # @return [String, nil] its source text
    def text(expr)
      return nil if expr.nil?
      return expr.to_s unless expr.respond_to?(:locator) && expr.locator

      expr.locator.extract_text(expr.offset, expr.length)
    end

    def relative(path, repo_dir)
      return path unless repo_dir

      path.delete_prefix("#{repo_dir.chomp('/')}/")
    end

    # @return [String] path
    def write(data, path)
      JsonDocument.write(data, path)
    end

    # @raise [JsonDocument::Error]
    def read(path)
      JsonDocument.read(path, document: DOCUMENT, schema_version: SCHEMA_VERSION)
    end
  end
end
