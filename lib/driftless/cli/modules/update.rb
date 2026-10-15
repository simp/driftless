require 'driftless/cli/base'
require 'driftless/cli/modules'
require 'driftless/control_repo'

module Driftless
  module CLI
    class Modules
      # `driftless modules update`
      #
      # Moves one deployed git module to a ref in place: fetches origin,
      # resolves the ref, and checks it out detached, as r10k would have.
      # The Puppetfile is left alone and named when it now disagrees.
      class Update < Base
        include Modules::OneModule

        register_command name: 'update', subcommand_of: Modules
        positional '<module>', '<ref>'
        desc 'Check out a ref in a deployed git module, in place'

        def execute(argv)
          fatal!('modules update takes a module and a ref', help: true) unless argv.size == 2
          selector, ref = argv
          repo = control_repo!('modules update')
          entry, clone = git_module!('modules update', repo, selector)
          fatal!("modules update: #{entry.path} has uncommitted changes; not touching it", 3) if clone.dirty?

          fatal!("modules update: fetch from #{clone.remote || 'origin'} failed", 3) unless clone.fetch
          candidate = ["origin/#{ref}", ref].find { |r| clone.resolve(r) }
          fatal!("modules update: #{ref.inspect} is not a ref #{clone.remote || 'origin'} has", 3) unless candidate
          target = clone.resolve(candidate)

          from = clone.tag_at_head || clone.branch_at_head || clone.sha.to_s[0, 12]
          if target == clone.sha
            puts "#{entry.path}: already at #{ref} (#{target[0, 12]})"
          elsif @options[:dry_run]
            puts "#{entry.path}: would move #{from} -> #{ref} (#{target[0, 12]})"
          else
            fatal!("modules update: checkout of #{target[0, 12]} failed in #{entry.path}", 3) unless clone.checkout(target)
            puts "#{entry.path}: #{from} -> #{ref} (#{target[0, 12]})"
          end
          declared = entry.declared&.ref
          if declared && declared.to_s != ref
            ::Driftless.logger.warn("modules update: the Puppetfile still declares #{entry.declared.ref_type} #{declared} for #{entry.path}")
          end
          exit 0
        end

        protected

        def configure_parser(o)
          declare_repo_option(o)
          o.on('--dry-run', 'Say what would change without checking anything out') { @options[:dry_run] = true }
          o.separator ''
          o.separator '<ref> is a branch, tag, or sha, tried as origin/<ref> first and then as given,'
          o.separator 'after fetching origin. The checkout is detached, as r10k leaves it. A clone with'
          o.separator 'uncommitted changes is not touched.'
        end
      end
    end
  end
end
