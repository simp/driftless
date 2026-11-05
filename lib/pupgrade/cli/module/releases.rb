require 'pupgrade/cli/base'
require 'pupgrade/cli/module_command'
require 'pupgrade/cli/surface'
require 'pupgrade/cli/table'
require 'pupgrade/clone_remote'
require 'driftless/git_clone'
require 'driftless/module_inventory'
require 'pupgrade/release_constraints'
require 'pupgrade/solve/candidates'
require 'pupgrade/surface'
require 'pupgrade/surface/targets'
require 'pupgrade/surface/timeline'

module Pupgrade
  module CLI
    class ModuleCommand
      # `pupgrade module releases`
      #
      # One module's releases: every tag naming a version on the branch it
      # follows, past and future, newest first, with the date of each and
      # the deployed one marked, from a ref onward when one is given; on
      # request, whether each meets a dependency version, a Puppet version,
      # or an operating system, and how an item of the API surface reads
      # in each. `--repo` reads another remote of the clone instead, its
      # refs fetched into a namespace of their own.
      class Releases < Base
        include Table
        include ModuleCommand::Shared
        include Surface::Shared

        register_command name: 'releases', subcommand_of: ModuleCommand
        positional '<module>[:<ref>]'
        desc 'List one module\'s releases, past and future: version, tag, and date, the deployed one marked'

        COLUMNS = %w[version tag released].freeze
        ORDERS  = %w[newest oldest].freeze

        # How a constraint or item cell is colored by its first word.
        STYLE = { 'ok' => [:green], 'needs' => [:red], 'missing' => [:red], 'absent' => [:red], 'changed:' => [:yellow] }.freeze

        def execute(argv)
          fatal!('module releases takes a module, with an optional :REF', help: true) unless argv.size == 1
          selector, sep, ref = argv.first.partition(':')
          ref = nil if sep.empty? || ref.empty?
          repo      = control_repo!('module releases')
          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          entry     = inventory.find(selector)
          fatal!("module releases: no module #{selector.inspect} on the modulepath or in the Puppetfile", 3) unless entry

          branch = @options[:branch] && given_branch('module releases', repo, entry)
          remote, space = remote_refs(entry, repo) if @options[:repo]
          candidates = ::Pupgrade::Solve::Candidates.new(repo.dir, branchfile: @options[:branchfile], include_heads: @options[:include_heads],
                                                         fetch: @options[:fetch], remote: space)
          list = candidates.releases(entry, branch: branch)
          candidates.warnings.each { |w| ::Pupgrade.logger.warn(w) }
          fatal!("module releases: #{entry.path}: #{list.reason}", 3) if list.is_a?(::Pupgrade::Solve::Candidates::Unsolvable)
          this_module!(entry, remote, list) if remote
          list = from(repo, entry, remote ? remote_ref!('module releases', entry, ::Driftless::GitClone.new(File.join(repo.dir, entry.path)), ref) : ref, list) if ref

          constraints = constraints(inventory)
          clone = ::Driftless::GitClone.new(File.join(repo.dir, entry.path))
          items, cells = item_columns(repo, entry, clone, list)
          rows = list.map.with_index do |c, i|
            row(clone, c, constraints) + cells.map { |column| column[i] } + [c.current ? paint('(deployed)', :green) : '']
          end
          rows.reverse! if @options[:order] == 'newest'
          print_table(COLUMNS + constraints.map(&:heading) + items.map(&:heading) + [''], rows)
          name = entry.metadata.name || entry.declared&.name || File.basename(entry.path)
          branch ||= (entry.declared.ref_type == 'branch') ? entry.declared.ref.to_s : branch_for(repo, entry)
          ::Pupgrade.logger.notice("module releases: #{name}: #{list.size} release(s)#{" from #{ref}" if ref}#{" on #{branch}" if branch}" \
                                   "#{" at #{remote.name} (#{remote.url})" if remote}")
          exit 0
        end

        protected

        def configure_parser(o)
          declare_repo_option(o)
          declare_repo_remote(o)
          o.on('--branch=BRANCHES', Array, 'Follow the first of these branches the clone has; with a branchfile, record it there') { |v| @options[:branch] = v }
          o.on('--branchfile=FILE', 'The branchfile naming the branch the module follows (config: modules.branchfile)') { |v| @options[:branchfile] = v }
          o.on('--fetch', 'Fetch the clone\'s origin first') { @options[:fetch] = true }
          o.on('--include-heads', 'The tip of the branch as a row') { @options[:include_heads] = true }
          o.on('--order=ORDER', ORDERS, 'newest (default) or oldest first') { |v| @options[:order] = v }
          o.separator ''
          o.separator 'Constraints, a column each (comma-separated, repeatable):'
          o.on('--with=DEP[,…]', Array, 'Each release\'s range on DEP against its deployed version, or DEP=VERSION') { |v| accumulate(:with, v) }
          o.on('--puppet=VERSION', 'Each release\'s Puppet requirement against VERSION (8 reads as 8.0.0)') { |v| @options[:puppet] = v }
          o.on('--os=NAME[,…]', Array, 'Each release\'s support for the OS, or a release of it as NAME=RELEASE') { |v| accumulate(:os, v) }
          o.separator ''
          o.separator 'Surface items, a column each (globs, case-insensitive; a parameter is CLASS::PARAM):'
          o.on('--item=GLOBS', Array, 'How each matching item of the API surface reads in each release') { |v| accumulate(:items, v) }
          o.on('--cache-dir=DIR', 'Where surface documents are kept (config: surface.cache_dir)') { |v| @options[:cache_dir] = v }
          o.on('--refresh', 'Extract the surfaces again, ignoring the cache') { @options[:refresh] = :all }
          o.separator ''
          o.separator '<ref> starts the list: releases older than its version are left out.'
          o.separator 'A constraint cell reads ok, needs RANGE (newer or older: which way the version would'
          o.separator 'have to move), missing, none (no such dependency), or undeclared. An item cell is the'
          o.separator 'item\'s signature or type where it first appears, then changed: ..., =, or absent.'
        end

        private

        # The `--repo` remote resolved and its refs fetched into their
        # namespace.
        #
        # @return [Array(CloneRemote::Remote, String)] the remote and the namespace
        def remote_refs(entry, repo)
          clone = ::Driftless::GitClone.new(File.join(repo.dir, entry.path))
          fatal!("module releases: #{entry.path} is not a git clone", 3) unless clone.own?

          remotes = ::Pupgrade::CloneRemote.new(clone.dir)
          remote  = remotes.resolve(@options[:repo])
          [remote, remotes.fetch_refs(remote)]
        rescue ::Pupgrade::CloneRemote::Error => e
          fatal!("module releases: --repo #{@options[:repo]}: #{e.message}", 3)
        end

        # Stops unless the remote's releases are this module's, by the
        # metadata at its newest one (the author may differ).
        def this_module!(entry, remote, list)
          there = list.last&.metadata&.name.to_s
          return if there.empty?

          mine = ::Pupgrade::ModuleName.short(entry.metadata.name || entry.declared&.name || File.basename(entry.path))
          return if ::Pupgrade::ModuleName.short(there) == mine

          fatal!("module releases: #{remote.name} (#{remote.url}) is #{there}, not a #{mine} module", 3)
        end

        # The releases from the ref onward: those whose version is not
        # below the metadata version at the ref.
        #
        # @return [Array<Solve::Candidates::Candidate>]
        def from(repo, entry, ref, list)
          start = ::Pupgrade::ReleaseConstraints.version(at_ref('module releases', repo, entry, ref).metadata.version.to_s)
          list.select { |c| c.version.nil? || c.version >= start }
        rescue ArgumentError => e
          fatal!("module releases: #{entry.path} at #{ref}: #{e.message}", 3)
        end

        # @return [Array<#heading, #check>] from --with, --puppet, and --os
        def constraints(inventory)
          out = Array(@options[:with]).map do |spec|
            name, _, version = spec.partition('=')
            if version.empty?
              version = inventory.find(name)&.metadata&.version
              fatal!("module releases: --with #{name}: not deployed, so no version to hold against; give #{name}=VERSION", 3) unless version
            end
            ::Pupgrade::ReleaseConstraints::Dependency.new(name, parse_version(version, "--with #{spec}"))
          end
          out << ::Pupgrade::ReleaseConstraints::Puppet.new(parse_version(@options[:puppet], '--puppet')) if @options[:puppet]
          out + Array(@options[:os]).map do |spec|
            os, _, release = spec.partition('=')
            ::Pupgrade::ReleaseConstraints::OperatingSystem.new(os, release.empty? ? nil : release)
          end
        end

        # The surface items --item names and how each reads per release,
        # from the document of the module at every release, through the
        # cache `surface` keeps.
        #
        # @return [Array(Array<Surface::Timeline::Item>, Array<Array<String>>)]
        #   the items, and per item one cell per release
        def item_columns(repo, entry, clone, list)
          globs = Array(@options[:items])
          return [[], []] if globs.empty?

          ::Pupgrade.logger.notice("module releases: reading the surface of #{entry.path} at #{list.size} release(s)")
          reader = targets(fetch: false)
          docs   = list.map do |candidate|
            ref = ref_candidate(clone, candidate.rev) || candidate.rev
            reader.document(reader.resolve(File.join(repo.dir, entry.path), ref: ref)).first
          end
          timeline = ::Pupgrade::Surface::Timeline.new(docs)
          items    = timeline.items(globs)
          ::Pupgrade.logger.warn("module releases: no surface item matches #{globs.join(', ')} at any release") if items.empty?
          [items, items.map { |item| timeline.cells(item).map { |cell| paint(cell, *STYLE.fetch(cell.split.first, [])) } }]
        rescue ::Pupgrade::Surface::Error, ::Pupgrade::Surface::Targets::Error => e
          fatal!("module releases: #{e.message}", 3)
        end

        def parse_version(text, what)
          ::Pupgrade::ReleaseConstraints.version(text)
        rescue ArgumentError => e
          fatal!("module releases: #{what}: #{e.message}", help: true)
        end

        def accumulate(key, values)
          (@options[key] ||= []).concat(values)
        end

        # A tag cyan and a branch tip magenta, the colors `module list` gives
        # a declaration; a constraint met green, missed red.
        def row(clone, candidate, constraints)
          ref   = paint(candidate.ref, (candidate.ref_type == 'tag') ? :cyan : :magenta)
          date  = clone.log('-1', '--format=%cs', "#{candidate.rev}^{commit}") || ''
          cells = constraints.map do |c|
            verdict = c.check(candidate.metadata)
            paint(verdict, *STYLE.fetch(verdict.split.first, []))
          end
          [candidate.version.to_s, ref, date] + cells
        end

        def option_defaults
          { order: 'newest' }
        end

        def config_defaults
          surface_config_defaults.merge(branchfile: ::Pupgrade.config.dig('modules', 'branchfile')).compact
        end
      end
    end
  end
end
