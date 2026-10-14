require 'driftless/cli/base'
require 'driftless/cli/params'
require 'driftless/cli/table'
require 'driftless/json_document'
require 'driftless/params_schema'
require 'driftless/params_schema/validate'

module Driftless
  module CLI
    class Params
      # `driftless params validate`
      #
      # One row per Hiera key or lookup() that names a class or param the
      # schema does not record; exit 1 when there are any.
      class Validate < Base
        include Params::RepoLoading
        include Table

        register_command name: 'validate', subcommand_of: Params
        desc 'Check Hiera keys and lookup() calls against a recorded schema'

        COLUMNS = %w[issue file line key detail].freeze

        def execute(argv)
          reject_extra_args!(argv)
          repo   = control_repo!('params validate')
          path   = schema_path(repo, @options[:against])
          schema =
            begin
              ::Driftless::ParamsSchema.read(path)
            rescue ::Driftless::JsonDocument::Error => e
              fatal!("params validate: #{e.message}", 3)
            end

          corpus = load_corpus(repo)
          issues = ::Driftless::ParamsSchema::Validate.new(
            schema,
            exclude_paths: @options[:exclude_paths], exclude_classes: @options[:exclude_classes],
            exclude_modules: @options[:exclude_modules], exclude_params: @options[:exclude_params],
          ).call(corpus)

          if issues.empty?
            puts 'no issues'
          else
            print_table(COLUMNS, issues.map { |i| [i.kind, i.path, i.line.to_s, i.key, i.detail] })
          end
          ::Driftless.logger.info("params validate: #{issues.size} issue(s) against #{path}")
          exit(issues.empty? ? 0 : 1)
        end

        protected

        def configure_parser(o)
          declare_repo_options(o)
          o.on('--against=FILE', 'The schema to check against',
               "(default params.schema_file, #{::Driftless::ParamsSchema::DEFAULT_FILE} relative to the repo)") { |v| @options[:against] = v }
          o.on('--hiera', 'Check Hiera data keys and lookup() calls (the default, and for now the only check)') { @options[:hiera] = true }
          o.separator ''
          o.separator 'Exits 1 when issues remain. params.exclude_paths|classes|modules|params in driftless.yaml'
          o.separator 'leave known Hiera-only keys unchecked.'
        end

        def config_defaults
          cfg = ::Driftless.config
          super.merge({
            exclude_paths:   cfg.dig('params', 'exclude_paths'),
            exclude_classes: cfg.dig('params', 'exclude_classes'),
            exclude_modules: cfg.dig('params', 'exclude_modules'),
            exclude_params:  cfg.dig('params', 'exclude_params'),
          }.compact)
        end
      end
    end
  end
end
