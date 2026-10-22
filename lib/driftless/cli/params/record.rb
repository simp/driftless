require 'driftless/cli/base'
require 'driftless/cli/params'
require 'driftless/params_schema'

module Driftless
  module CLI
    class Params
      # `driftless params record`
      #
      # Writes the params document for the repo as it stands.
      class Record < Base
        include Params::RepoLoading

        register_command name: 'record', subcommand_of: Params
        desc 'Write the schema: every class and its params, with the repo revision'

        def execute(argv)
          reject_extra_args!(argv)
          repo   = control_repo!('params record')
          corpus = load_corpus(repo)
          path   = ::Driftless::ParamsSchema.write(::Driftless::ParamsSchema.assemble(corpus: corpus), schema_path(repo, @options[:output]))
          ::Driftless.logger.notice("params record: #{corpus.puppet_classes.size} classes")
          puts path
          exit 0
        end

        protected

        def configure_parser(o)
          declare_repo_options(o)
          o.on('-o', '--output=FILE', 'Write here instead of params.schema_file',
               "(default #{::Driftless::ParamsSchema::DEFAULT_FILE}, relative to the repo)") { |v| @options[:output] = v }
        end
      end
    end
  end
end
