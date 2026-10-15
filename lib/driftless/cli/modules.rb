require 'driftless/cli/base'
require 'driftless/cli/root'

module Driftless
  module CLI
    # `driftless modules`: the parent of the module checks.
    class Modules < Base
      register_command name: 'modules', subcommand_of: Root
      desc 'Check the modules a control repo deploys (see subcommands)'

      # What the commands acting on one module share: finding the repo and
      # the module named on the command line.
      module OneModule
        def declare_repo_option(o)
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

        # The module's entry and its clone, stopping unless it is a git
        # clone on disk.
        #
        # @return [Array(ModuleInventory::Entry, GitClone)]
        def git_module!(command, repo, selector)
          require 'driftless/git_clone'
          require 'driftless/module_inventory'

          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          entry     = inventory.find(selector)
          inventory.warnings.each { |w| ::Driftless.logger.warn(w) }
          fatal!("#{command}: no module #{selector.inspect} on the modulepath or in the Puppetfile", 3) unless entry
          fatal!("#{command}: #{entry.path} is not deployed", 3) if entry.deployed == :absent

          clone = ::Driftless::GitClone.new(File.join(repo.dir, entry.path))
          fatal!("#{command}: #{entry.path} is not a git clone", 3) unless clone.own?
          [entry, clone]
        end
      end
    end
  end
end

Dir[File.join(__dir__, 'modules', '*.rb')].sort.each { |f| require f }
