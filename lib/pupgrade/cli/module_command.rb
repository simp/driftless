require 'open3'

require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'driftless/git_clone'
require 'driftless/inputs/module_metadata'
require 'pupgrade/clone_remote'
require 'pupgrade/inputs/branchfile'
require 'pupgrade/module_name'

module Pupgrade
  module CLI
    # `pupgrade module`: the parent of the commands that act on one
    # deployed module. Named apart from ::Module, which the command's name
    # would shadow inside this namespace.
    class ModuleCommand < Base
      register_command name: 'module', subcommand_of: Root
      desc 'One deployed module: list them, show one, compare two versions, read its git log, or move it'

      # What the commands acting on one module share: finding the repo and
      # the module named on the command line.
      module Shared
        def declare_repo_option(o)
          o.on('-d', '--repo-dir=DIR',
               'Path to the control repo environment',
               "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        end

        def declare_repo_remote(o)
          o.on('--repo=URL[,REMOTE]|REMOTE', 'Run against this remote of the clone: one it has by name, one at URL (added as',
               'pupgrade-<hash> when none is), or REMOTE added or pointed at URL; <ref> must be there') { |v| @options[:repo] = v }
        end

        # The ref fetched from the `--repo` remote: the remote resolved and
        # fetched, and the metadata there checked to be this module (its
        # name's module part; the author may differ).
        #
        # @return [String] the sha
        def remote_ref!(command, entry, clone, ref)
          remotes = ::Pupgrade::CloneRemote.new(clone.dir)
          remote  = remotes.resolve(@options[:repo])
          sha     = remotes.fetch(remote, ref)
          text, status = Open3.capture2('git', '-C', clone.dir, 'show', "#{sha}:#{::Driftless::Inputs::ModuleMetadata::FILENAME}", err: File::NULL)
          fatal!("#{command}: #{remote.name} (#{remote.url}) at #{ref} has no metadata.json; not a Puppet module", 3) unless status.success?

          metadata = ::Driftless::Inputs::ModuleMetadata.parse(text, path: "#{remote.name}@#{ref}:metadata.json")
          fatal!("#{command}: #{metadata.error}", 3) if metadata.error
          mine = ::Pupgrade::ModuleName.short(entry.metadata.name || entry.declared&.name || File.basename(entry.path))
          there = ::Pupgrade::ModuleName.short(metadata.name.to_s)
          fatal!("#{command}: #{remote.name} at #{ref} is #{metadata.name}, not a #{mine} module", 3) unless there == mine
          ::Pupgrade.logger.info("#{command}: #{ref} on #{remote.name} is #{metadata.name} #{metadata.version} (#{sha[0, 12]})")
          sha
        rescue ::Pupgrade::CloneRemote::Error => e
          fatal!("#{command}: --repo #{@options[:repo]}: #{e.message}", 3)
        end

        # @return [Driftless::ControlRepo]
        def control_repo!(command)
          repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
          fatal!("#{command} requires --repo-dir (auto-detection did not supply it)", help: true) unless repo
          fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
          repo
        end

        # The module's entry and its clone, stopping unless it is a git
        # clone on disk.
        #
        # @return [Array(Driftless::ModuleInventory::Entry, Driftless::GitClone)]
        def git_module!(command, repo, selector)
          require 'driftless/git_clone'
          require 'driftless/module_inventory'

          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          entry     = inventory.find(selector)
          inventory.warnings.each { |w| ::Pupgrade.logger.warn(w) }
          fatal!("#{command}: no module #{selector.inspect} on the modulepath or in the Puppetfile", 3) unless entry
          fatal!("#{command}: #{entry.path} is not deployed", 3) if entry.deployed == :absent

          clone = ::Driftless::GitClone.new(File.join(repo.dir, entry.path))
          fatal!("#{command}: #{entry.path} is not a git clone", 3) unless clone.own?
          [entry, clone]
        end

        # The first of the branches the clone knows, either origin/<branch>
        # or the name given.
        #
        # @return [String]
        def pick_branch(command, clone, branches)
          found = branches.find { |b| clone.resolve("origin/#{b}") || clone.resolve(b) }
          fatal!("#{command}: none of #{branches.join(', ')} is a branch the clone knows (try --fetch)", 3) unless found
          found
        end

        # The first --branch the clone knows, recorded in the branchfile
        # when there is one.
        #
        # @return [String]
        def given_branch(command, repo, entry)
          clone = ::Driftless::GitClone.new(File.join(repo.dir, entry.path))
          fatal!("#{command}: #{entry.path} is not a git clone, so follows no branch", 3) unless clone.own?

          branch = pick_branch(command, clone, @options[:branch])
          record_branch(command, repo, entry, branch) if @options[:branchfile]
          branch
        end

        # @return [String, nil] the branch the branchfile names for the
        #   module, under any of its names
        def branch_for(repo, entry)
          return nil unless @options[:branchfile]

          result = ::Pupgrade::Inputs::Branchfile.load(File.expand_path(@options[:branchfile], repo.dir))
          return nil if result.error || !result.exists?

          [entry.declared&.name, entry.metadata.name, File.basename(entry.path)].compact.filter_map { |n| result.branch_for(n) }.first
        end

        # Writes the branch for the module into the branchfile, the one on
        # the command line or the configured one, under the Puppetfile's
        # name for it.
        def record_branch(command, repo, entry, branch)
          path = File.expand_path(@options[:branchfile], repo.dir)
          name = entry.declared&.name || entry.metadata.name || File.basename(entry.path)
          ::Pupgrade::Inputs::Branchfile.record(path, name, branch)
          ::Pupgrade.logger.notice("#{command}: recorded #{name}: #{branch} in #{path}")
        rescue ::Pupgrade::Inputs::Branchfile::Error => e
          fatal!("#{command}: branchfile #{e.message}", 3)
        end

        # A git module's declared ref as [kind, name, why]. A
        # `:control_branch` is the branch its clone is on, the one r10k
        # deployed: the control repo's branch under `deploy environment`, the
        # `default_branch` under `puppetfile install`. `why` names which
        # (`default_branch` when the clone is on it and the control repo is
        # not); nil for any other ref, and for a clone that cannot say.
        #
        # @return [Array(String, String, String), Array(String, String, nil)]
        def declared_ref(repo, entry)
          declared = entry.declared
          return [declared.ref_type || 'ref', (declared.ref || 'HEAD').to_s, nil] unless declared.ref == :control_branch

          clone = ::Driftless::GitClone.new(File.join(repo.dir, entry.path))
          return ['branch', 'control_branch', nil] unless clone.own?

          control = ::Driftless::GitClone.new(repo.dir)
          control = control.own? ? control.current_branch : nil
          control = nil if control == 'HEAD'
          branch  = [control, declared.default_branch].compact.find { |b| clone.branch_at_head(prefer: b) == b } || clone.branch_at_head
          return ['branch', 'control_branch', nil] unless branch

          ['branch', branch, (branch == declared.default_branch && branch != control) ? 'default_branch' : 'control_branch']
        end

        # A ref of a clone and the module's metadata there.
        #
        # @!attribute [r] ref
        #   @return [String] as given
        # @!attribute [r] name
        #   @return [String] as the clone resolves it, from {#ref_candidate}
        # @!attribute [r] sha
        #   @return [String]
        # @!attribute [r] metadata
        #   @return [Driftless::Inputs::ModuleMetadata::Result] the metadata there
        At = Data.define(:ref, :name, :sha, :metadata)

        # The module's metadata at a ref of its clone. The ref resolves
        # through {#ref_candidate}: `origin/<ref>` first.
        #
        # @return [At]
        def at_ref(command, repo, entry, ref)
          clone = ::Driftless::GitClone.new(File.join(repo.dir, entry.path))
          fatal!("#{command}: #{entry.path} is not a git clone, so has no ref #{ref.inspect}", 3) unless clone.own?
          name = ref_candidate(clone, ref)
          fatal!("#{command}: #{entry.path} has no ref #{ref.inspect}", 3) unless name

          sha = clone.resolve(name)
          text, status = Open3.capture2('git', '-C', clone.dir, 'show', "#{sha}:#{::Driftless::Inputs::ModuleMetadata::FILENAME}", err: File::NULL)
          fatal!("#{command}: #{entry.path} has no metadata.json at #{ref}", 3) unless status.success?

          metadata = ::Driftless::Inputs::ModuleMetadata.parse(text, path: "#{entry.path}@#{ref}:metadata.json")
          fatal!("#{command}: #{metadata.error}", 3) if metadata.error
          At.new(ref: ref, name: name, sha: sha, metadata: metadata)
        end

        # Git's own rev syntax: a suffix, a reflog or range operator.
        REV_EXPRESSION = /[\^~:]|@\{|\.\./.freeze

        # The ref as git should see it: a rev expression (`HEAD~2`,
        # `main@{2.weeks.ago}`) as given, since prefixing it would change its
        # meaning; a plain name as `origin/<name>` when the clone has that,
        # since a deployed clone's own branches are stale, else as given.
        #
        # @return [String, nil] nil when the clone resolves neither
        def ref_candidate(clone, ref)
          names = ref.match?(REV_EXPRESSION) ? [ref] : ["origin/#{ref}", ref]
          names.find { |r| clone.resolve(r) }
        end
      end
    end
  end
end

Dir[File.join(__dir__, 'module', '*.rb')].sort.each { |f| require f }
