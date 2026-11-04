require 'pupgrade/cli/base'
require 'pupgrade/cli/module_command'
require 'driftless/control_repo'

module Pupgrade
  module CLI
    class ModuleCommand
      # `pupgrade module update`
      #
      # Moves one deployed git module to a ref in place: fetches origin, or
      # the remote `--repo` names, resolves the ref, and checks it out
      # detached, as r10k would have. The Puppetfile is left alone and
      # named when it now disagrees.
      class Update < Base
        include ModuleCommand::Shared

        register_command name: 'update', subcommand_of: ModuleCommand
        positional '<module>', '<ref>'
        desc 'Check out a ref in a deployed git module, in place'

        def execute(argv)
          fatal!('module update takes a module and a ref', help: true) unless argv.size == 2
          selector, ref = argv
          repo = control_repo!('module update')
          entry, clone = git_module!('module update', repo, selector)
          # a deleted spec/ is r10k's doing, not a local change; the checkout
          # is forced over it, which discards nothing else since nothing else
          # is changed
          removed_spec = clone.dirty?
          fatal!("module update: #{entry.path} has uncommitted changes; not touching it (--force overrides)", 3) if !@options[:force] && clone.dirty?(ignore: ::Driftless::GitClone::R10K_REMOVED_SPEC)

          if @options[:repo]
            target = remote_ref!('module update', entry, clone, ref)
          else
            fatal!("module update: fetch from #{clone.remote || 'origin'} failed", 3) unless clone.fetch
            candidate = ref_candidate(clone, ref)
            fatal!("module update: #{ref.inspect} is not a ref the clone resolves after fetching #{clone.remote || 'origin'}", 3) unless candidate
            target = clone.resolve(candidate)
          end

          from = clone.tag_at_head || clone.branch_at_head || clone.sha.to_s[0, 12]
          if target == clone.sha
            puts "#{entry.path}: already at #{ref} (#{target[0, 12]})"
          elsif @options[:dry_run]
            puts "#{entry.path}: would move #{from} -> #{ref} (#{target[0, 12]})"
          else
            fatal!("module update: checkout of #{target[0, 12]} failed in #{entry.path}", 3) unless clone.checkout(target, force: @options[:force] || removed_spec)
            puts "#{entry.path}: #{from} -> #{ref} (#{target[0, 12]})"
          end
          declared = entry.declared&.ref
          if declared && declared.to_s != ref
            ::Pupgrade.logger.warn("module update: the Puppetfile still declares #{entry.declared.ref_type} #{declared} for #{entry.path}")
          end
          exit 0
        end

        protected

        def configure_parser(o)
          declare_repo_option(o)
          o.on('--dry-run', 'Say what would change without checking anything out') { @options[:dry_run] = true }
          o.on('--force', 'Check out over uncommitted changes in the clone, discarding them') { @options[:force] = true }
          declare_repo_remote(o)
          o.separator ''
          o.separator '<ref> is a branch, tag, or sha, tried as origin/<ref> first and then as given, after'
          o.separator 'fetching origin; a rev expression such as HEAD~3 goes to git as written. The'
          o.separator 'checkout is detached, as r10k leaves it. A clone with uncommitted changes is not'
          o.separator 'touched unless --force; a deleted spec/, which r10k removes, is not a change.'
        end
      end
    end
  end
end
