require 'driftless/cli/base'
require 'driftless/cli/root'
require 'driftless/codebase'
require 'driftless/control_repo'
require 'driftless/params_schema'

module Driftless
  module CLI
    # `driftless params`: the parent of the class-param schema commands.
    class Params < Base
      register_command name: 'params', subcommand_of: Root
      desc 'Record the schema of class params, validate data against it, or compare two recordings'

      # What `record` and `validate` share: finding the repo and loading its
      # code and data.
      module RepoLoading
        def declare_repo_options(o)
          o.on('-d', '--repo-dir=DIR',
               'Path to the control repo environment',
               "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        end

        # @return [ControlRepo]
        def control_repo!(command)
          repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
          fatal!("#{command} requires --repo-dir (auto-detection did not supply it)", help: true) unless repo
          fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
          repo
        end

        # Loads the repo, logging what could not be read.
        #
        # @return [Corpus]
        def load_corpus(repo)
          code = ::Driftless::Codebase.load(repo.dir)
          (code.warnings + code.findings.map(&:message)).each { |m| ::Driftless.logger.warn(m) }
          code.corpus(repo_dir: repo.dir)
        end

        # The schema file: --against or --output when given, else
        # params.schema_file relative to the repo.
        def schema_path(repo, explicit)
          File.expand_path(explicit || @options[:schema_file] || ::Driftless::ParamsSchema::DEFAULT_FILE, repo.dir)
        end

        def config_defaults
          { schema_file: ::Driftless.config.dig('params', 'schema_file') }.compact
        end
      end
    end
  end
end

Dir[File.join(__dir__, 'params', '*.rb')].sort.each { |f| require f }
