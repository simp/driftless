require 'driftless/cli/base'
require 'driftless/cli/list'
require 'driftless/cli/table'
require 'driftless/control_repo'
require 'driftless/module_inventory'

module Driftless
  module CLI
    class List
      # `driftless list modules`
      #
      # One row per module the control repo holds on its modulepath or
      # declares in its Puppetfile, keyed by the directory r10k deploys to.
      class Modules < Base
        include Table

        register_command name: 'modules', subcommand_of: List
        desc 'List modules on the modulepath and in the Puppetfile'

        COLUMNS = %w[path name ref version pupver].freeze

        # Prefixed to the ref cell: how the clone on disk compares with the
        # declared ref.
        DEPLOYED_MARK = { match: '=', differ: '*', unknown: '?' }.freeze

        def execute(_argv)
          repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
          fatal!('list modules requires --repo-dir (auto-detection did not supply it)', help: true) unless repo
          fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?

          inventory = ::Driftless::ModuleInventory.new(repo.dir, basemodulepath: @options[:basemodulepath])
          entries   = inventory.entries
          inventory.warnings.each { |w| ::Driftless.logger.warn(w) }
          entries.each { |e| ::Driftless.logger.warn(e.metadata.error) if e.metadata.error }
          entries = entries.select { |e| e.declared&.git } if @options[:git_only]

          rows = entries.map do |e|
            [e.path, e.metadata.name.to_s, ref_cell(e), e.metadata.version.to_s, e.metadata.puppet_requirement.to_s]
          end
          print_table(COLUMNS, rows)
          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-d', '--repo-dir=DIR',
               'Path to the control repo environment',
               "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
          o.on('--basemodulepath=PATH', 'Override $basemodulepath (colon-separated)') { |v| @options[:basemodulepath] = v.split(':') }
          o.on('--git', 'Only modules the Puppetfile deploys from git') { @options[:git_only] = true }
          o.separator ''
          o.separator 'The ref column prefixes the declared ref with how the clone on disk compares:'
          o.separator '  = at that ref, * elsewhere, ? no clone to ask'
        end

        private

        # The declared ref (":control_branch (default_branch)" when it is
        # that) behind its deployed mark; empty for a module not from git.
        def ref_cell(entry)
          declared = entry.declared
          return '' unless declared&.git

          ref = declared.ref.to_s
          ref = [ref, declared.default_branch && "(#{declared.default_branch})"].compact.join(' ') if declared.ref == :control_branch
          "#{DEPLOYED_MARK.fetch(entry.deployed)}#{ref}"
        end
      end
    end
  end
end
