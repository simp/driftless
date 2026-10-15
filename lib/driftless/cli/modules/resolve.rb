require 'driftless/cli/base'
require 'driftless/cli/modules'
require 'driftless/cli/table'
require 'driftless/control_repo'
require 'driftless/module_inventory'
require 'driftless/module_proposal'
require 'driftless/module_resolver'

module Driftless
  module CLI
    class Modules
      # `driftless modules resolve`
      #
      # One row per conflict between the modules' metadata; exit 1 when any
      # remain. With --propose, the conflicts a proposed Puppetfile would
      # leave, marked against the current ones.
      class Resolve < Base
        include Table

        register_command name: 'resolve', subcommand_of: Modules
        desc 'Check modules against each other: dependencies, Puppet versions, operating systems'

        COLUMNS = %w[conflict module subject detail].freeze

        # Prefixed to each row under --propose: how the conflict relates to
        # the current Puppetfile's.
        CHANGE_MARK = { new: '+', gone: '-', same: ' ' }.freeze

        def execute(_argv)
          repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
          fatal!('modules resolve requires --repo-dir (auto-detection did not supply it)', help: true) unless repo
          fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?

          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          resolver  = ::Driftless::ModuleResolver.new(operatingsystems: @options[:operatingsystems], exclude: @options[:exclude])
          current   = resolver.resolve(inventory.entries)
          log_warnings(inventory.warnings + current.warnings)

          if @options[:propose]
            proposal = ::Driftless::ModuleProposal.new(inventory, File.expand_path(@options[:propose]))
            result   = resolver.resolve(proposal.entries)
            log_warnings(proposal.warnings + result.warnings)
            print_table(['change'] + COLUMNS, change_rows(current, result))
          else
            result = current
            print_table(COLUMNS, result.conflicts.map { |c| row(c) })
          end

          ::Driftless.logger.info(summary(result))
          exit(result.conflicts.empty? ? 0 : 1)
        rescue ::Driftless::ModuleProposal::Error => e
          fatal!("modules resolve: #{e.message}")
        end

        protected

        def configure_parser(o)
          o.on('-d', '--repo-dir=DIR',
               'Path to the control repo environment',
               "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
          o.on('--propose=PUPPETFILE',
               'Resolve as if PUPPETFILE replaced the current entries at the same paths;',
               'metadata for a changed module is read from its git remote.',
               'Rows are marked + (new conflict), - (resolved), or unchanged') { |v| @options[:propose] = v }
          o.separator ''
          o.separator 'Exits 1 when conflicts remain. In driftless.yaml, modules.operatingsystems names the'
          o.separator 'operating systems of interest, modules.exclude_modules leaves modules out of every check,'
          o.separator 'and modules.exclude_dependencies|requirements|operatingsystems drop known conflicts.'
        end

        private

        def row(conflict)
          [conflict.kind, conflict.module, conflict.subject, conflict.detail]
        end

        # The proposed conflicts, then those the proposal resolves, each
        # behind its change mark. Conflicts match by kind, module, and subject.
        def change_rows(current, proposed)
          key = ->(c) { [c.kind, c.module, c.subject] }
          before = current.conflicts.to_h { |c| [key.call(c), c] }
          after  = proposed.conflicts.to_h { |c| [key.call(c), c] }
          rows   = proposed.conflicts.map { |c| [CHANGE_MARK[before.key?(key.call(c)) ? :same : :new]] + row(c) }
          rows + current.conflicts.reject { |c| after.key?(key.call(c)) }.map { |c| [CHANGE_MARK[:gone]] + row(c) }
        end

        def summary(result)
          puppet = result.puppet_range ? "puppet #{result.puppet_range} satisfies every requirement" : 'no puppet version satisfies every requirement'
          "modules resolve: #{result.conflicts.size} conflict(s), #{result.excluded} excluded; #{puppet}"
        end

        def log_warnings(warnings)
          warnings.each { |w| ::Driftless.logger.warn(w) }
        end

        def config_defaults
          cfg = ::Driftless.config
          {
            operatingsystems: cfg.dig('modules', 'operatingsystems'),
            exclude:          {
              'modules'          => cfg.dig('modules', 'exclude_modules'),
              'dependencies'     => cfg.dig('modules', 'exclude_dependencies'),
              'requirements'     => cfg.dig('modules', 'exclude_requirements'),
              'operatingsystems' => cfg.dig('modules', 'exclude_operatingsystems'),
            }.compact,
          }.compact
        end
      end
    end
  end
end
