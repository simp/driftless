require 'driftless/cli/base'
require 'driftless/cli/list'
require 'driftless/cli/table'
require 'driftless/control_repo'
require 'driftless/inputs/modulepath_loader'

module Driftless
  module CLI
    class List
      # `driftless list roles`
      #
      # One row per role class defined in the control repo's code, with the
      # manifest that defines it.
      class Roles < Base
        include Table

        register_command name: 'roles', subcommand_of: List
        desc 'List role classes defined in the control repo'

        COLUMNS = %w[role file].freeze

        def execute(_argv)
          require 'driftless/class_extractor'
          require 'driftless/inputs/manifest_parser'

          repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
          fatal!('list roles requires --repo-dir (auto-detection did not supply it)', help: true) unless repo
          fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?

          files, findings = ::Driftless::Inputs::ModulepathLoader.load(repo.dir, **modulepath_args)
          roles = files.flat_map do |path|
            program, errs = ::Driftless::Inputs::ManifestParser.parse(path)
            findings.concat(errs)
            next [] unless program
            ::Driftless::ClassExtractor.extract(program: program, file: path).select(&:role?)
          end
          findings.each { |f| ::Driftless.logger.warn(f.message) }

          rows = roles.sort_by(&:fqname).map { |c| [c.fqname, c.file.sub("#{repo.dir}/", '')] }
          print_table(COLUMNS, rows)
          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-d', '--repo-dir=DIR',
               'Path to the control repo environment',
               "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
          o.on('--basemodulepath=PATH', 'Override $basemodulepath (colon-separated)') { |v| @options[:basemodulepath] = v.split(':') }
        end

        private

        def modulepath_args
          @options[:basemodulepath] ? { basemodulepath: @options[:basemodulepath] } : {}
        end
      end
    end
  end
end
