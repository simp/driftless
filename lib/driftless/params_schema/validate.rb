require 'set'

require 'driftless/config_keys'
require 'driftless/params_schema'
require 'driftless/role_profile'

module Driftless
  module ParamsSchema
    # Checks a repo's uses of class params against a recorded params
    # document. A Hiera `class::param` key must name a recorded class and
    # one of its params; a lookup() of such a key must name one of the
    # class's params. The exemptions follow the detectors: a Hiera key some
    # lookup() asks for by name is not held to naming a class (as
    # `data:codebase-missing-class`), and under a role or profile namespace
    # is not held to naming a param either (as `data:codebase-missing-class-param`
    # with allow_role_profile_keys), since those namespaces hold Hiera-only
    # keys by convention. A lookup() under those namespaces is not checked,
    # and neither is a module's lookup() of its own namespace (as
    # `code:lookup-missing-hiera-keys`): that is the module reading its own
    # data, which is not scanned.
    class Validate
      extend ConfigKeys::DSL

      config_key 'params.exclude_paths', type: :array, default: [],
                 about: 'Globs of repo-relative files (data files, manifests, templates) whose keys are not checked'
      config_key 'params.exclude_classes', type: :array, default: [],
                 about: 'Globs of class names whose keys are not checked'
      config_key 'params.exclude_modules', type: :array, default: [],
                 about: 'Module names whose classes are not checked'
      config_key 'params.exclude_params', type: :array, default: [],
                 about: 'Globs of class::param keys that are not checked'

      KINDS = %w[missing-class missing-param].freeze

      # One use of a param the schema does not record.
      #
      # @!attribute [r] kind
      #   @return [String] one of {KINDS}
      # @!attribute [r] path
      #   @return [String] repo-relative file
      # @!attribute [r] line
      #   @return [Integer, nil]
      # @!attribute [r] key
      #   @return [String] the `class::param` key as used
      # @!attribute [r] detail
      #   @return [String] what the schema records instead
      Issue = Data.define(:kind, :path, :line, :key, :detail)

      # @param schema [Hash] a params document, from {ParamsSchema.read}
      # @param exclude_paths [Array<String>] see the config keys
      def initialize(schema, exclude_paths: [], exclude_classes: [], exclude_modules: [], exclude_params: [])
        @classes         = schema.fetch('classes')
        @exclude_paths   = Array(exclude_paths)
        @exclude_classes = Array(exclude_classes)
        @exclude_modules = Array(exclude_modules)
        @exclude_params  = Array(exclude_params)
      end

      # @param corpus [Corpus] the repo as {Codebase} loaded it
      # @return [Array<Issue>] by path, line, key
      def call(corpus)
        lookups  = corpus.code_lookup_calls + corpus.data_lookup_calls
        explicit = lookups.map(&:key).to_set
        issues   = []

        corpus.data_files.each do |df|
          path = ParamsSchema.relative(df.path, corpus.repo_dir)
          next if excluded_path?(path)

          df.top_level_keys.each do |key, line|
            looked_up = explicit.include?(key)
            issues << check(key, path, line, missing_class: !looked_up, hiera_only_ok: looked_up)
          end
        end
        lookups.each do |lc|
          path = ParamsSchema.relative(lc.file, corpus.repo_dir)
          next if excluded_path?(path)
          next if RoleProfile.role?(lc.key) || RoleProfile.profile?(lc.key) || lc.module_local?

          issues << check(lc.key, path, lc.line, missing_class: false, hiera_only_ok: false)
        end
        issues.compact.uniq.sort_by { |i| [i.path, i.line || 0, i.key] }
      end

      private

      # @param missing_class [Boolean] whether an unrecorded class is an issue
      # @param hiera_only_ok [Boolean] whether a role or profile class may
      #   carry the key without a param
      # @return [Issue, nil]
      def check(key, path, line, missing_class:, hiera_only_ok:)
        return nil unless key.include?('::')

        class_name, _, param = key.rpartition('::')
        return nil if excluded_class?(class_name) || excluded_param?(key)

        recorded = @classes[class_name]
        if recorded.nil?
          return nil unless missing_class

          Issue.new(kind: 'missing-class', path: path, line: line, key: key, detail: "class #{class_name} is not in the schema")
        elsif !recorded['params'].key?(param)
          return nil if hiera_only_ok && (RoleProfile.role?(class_name) || RoleProfile.profile?(class_name))

          names = recorded['params'].keys
          shown = names.first(8).join(', ')
          shown += ", #{names.size - 8} more" if names.size > 8
          Issue.new(kind: 'missing-param', path: path, line: line, key: key,
                    detail: "#{class_name} has no param #{param} (has: #{shown.empty? ? 'none' : shown})")
        end
      end

      def excluded_path?(path)
        @exclude_paths.any? { |g| File.fnmatch(g, path, File::FNM_EXTGLOB) }
      end

      def excluded_class?(class_name)
        @exclude_modules.include?(class_name.split('::').first) ||
          @exclude_classes.any? { |g| File.fnmatch(g, class_name, File::FNM_EXTGLOB) }
      end

      def excluded_param?(key)
        @exclude_params.any? { |g| File.fnmatch(g, key, File::FNM_EXTGLOB) }
      end
    end
  end
end
