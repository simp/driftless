require 'pupgrade/cli/base'
require 'pupgrade/cli/module_command'
require 'pupgrade/cli/surface'
require 'pupgrade/cli/table'
require 'driftless/control_repo'
require 'driftless/git_clone'
require 'driftless/module_inventory'
require 'pupgrade/inputs/branchfile'
require 'pupgrade/solve/candidates'
require 'pupgrade/surface/diff'
require 'pupgrade/surface/targets'

module Pupgrade
  module CLI
    class ModuleCommand
      # `pupgrade module info`
      #
      # One module in full: its names, where it is, what the Puppetfile
      # declares, what the clone sits at, what its metadata claims (at a ref
      # of the clone, when one is named), the branch it follows, the
      # versions it could move to, and on request the names on each of its
      # API surfaces.
      class Info < Base
        include Table
        include ModuleCommand::Shared
        include Surface::Shared

        register_command name: 'info', subcommand_of: ModuleCommand
        positional '<module>[:<ref>]'
        desc 'Show one module: names, declaration, deployment, metadata, branch, and candidates'

        SECTIONS = ::Pupgrade::Surface::Diff::SECTIONS

        def execute(argv)
          fatal!('module info takes a module', help: true) unless argv.size == 1
          check_surfaces!
          repo = control_repo!('module info')
          require 'driftless/module_inventory'
          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          name, sep, ref = argv.first.rpartition(':')
          if sep.empty? || ref.empty?
            name = argv.first
            ref  = nil
          end
          entry = inventory.find(name)
          fatal!("module info: no module #{name.inspect} on the modulepath or in the Puppetfile", 3) unless entry

          @branch = @options[:branch] && given_branch('module info', repo, entry)
          at = ref && at_ref('module info', repo, entry, ref)
          out = lines(repo, entry, at)
          out.concat(surface_lines(repo, entry, at)) if @options[:surfaces]
          out.each { |label, value| puts "#{label}:".ljust(15) + value.to_s }
          exit 0
        end

        protected

        def configure_parser(o)
          declare_repo_option(o)
          o.on('--branch=BRANCHES', Array, 'Follow the first of these branches the clone has; with a branchfile, record it there') { |v| @options[:branch] = v }
          o.on('--branchfile=FILE', 'The branchfile naming the branch the module follows (config: modules.branchfile)') { |v| @options[:branchfile] = v }
          o.on('--fetch', 'Fetch the clone\'s origin before listing candidates') { @options[:fetch] = true }
          o.on('--surfaces[=KINDS]', Array, "Also the names on each API surface (#{SECTIONS.join(', ')}; * for every kind, empty ones too)") { |v| @options[:surfaces] = v || [] }
        end

        private

        # @param at [Shared::At, nil] from {Shared#at_ref}
        def lines(repo, entry, at)
          declared = entry.declared
          metadata = at ? at.metadata : entry.metadata
          out = []
          out << ['name', [metadata.name, declared&.name].compact.uniq.join(', ')]
          out << ['path', entry.path]
          out << ['declared', declared ? declaration(repo, entry) : 'not in the Puppetfile']
          out << ['remote', declared.git] if declared&.git
          out.concat(clone_lines(repo, entry))
          out << ['deployed', entry.found ? "#{entry.deployed} (#{entry.found})" : entry.deployed.to_s]
          out << ['read at', "#{at.ref} (#{at.sha[0, 12]})"] if at
          out << ['version', metadata.version.to_s]
          out << ['dependencies', metadata.dependencies.map { |n, r| [paint(n, :cyan), r].compact.join(' ') }.join('; ')] unless metadata.dependencies.empty?
          out << ['requirements', metadata.requirements.map { |n, r| "#{paint(n, :cyan)} #{r}" }.join('; ')] unless metadata.requirements.empty?
          unless metadata.operatingsystem_support.empty?
            out << ['OS support', metadata.operatingsystem_support.map { |os, rel| "#{os} #{Array(rel).join('/')}".strip }.join(', ')]
          end
          out.concat(candidate_lines(repo, entry))
          out
        end

        # One line per surface kind, the names on it sorted, from the
        # module's document at the ref read or as deployed. A kind with
        # nothing on it is left out unless --surfaces names it, or is `*`.
        #
        # @return [Array<Array(String, String)>]
        def surface_lines(repo, entry, at)
          reader = targets
          doc, = reader.document(reader.resolve(File.join(repo.dir, entry.path), ref: at&.name))
          kinds = @options[:surfaces]
          kinds = SECTIONS if kinds == ['*']
          (kinds.empty? ? SECTIONS : kinds).filter_map do |section|
            names = doc.fetch(section, {}).keys.sort
            next if names.empty? && kinds.empty?

            [section.tr('_', ' '), names.empty? ? paint('(none)', :dim) : names.map { |n| paint(n, :cyan) }.join(', ')]
          end
        rescue ::Pupgrade::Surface::Error, ::Pupgrade::Surface::Targets::Error => e
          fatal!("module info: #{e.message}", 3)
        end

        def check_surfaces!
          unknown = Array(@options[:surfaces]) - SECTIONS - ['*']
          fatal!("module info: unknown surface #{unknown.first.inspect} (known: #{SECTIONS.join(', ')})", help: true) if unknown.any?
        end

        def declaration(repo, entry)
          declared = entry.declared
          return '(no version) (local)' if declared.local
          return "#{declared.version || '(no version)'} (forge)" unless declared.git

          kind, name, why = declared_ref(repo, entry)
          "#{kind} #{name}#{" (#{why})" if why}"
        end

        def clone_lines(repo, entry)
          dir = File.join(repo.dir, entry.path)
          return [] unless File.directory?(dir)

          clone = ::Driftless::GitClone.new(dir)
          return [] unless clone.own?

          at = [clone.tag_at_head && "tag #{clone.tag_at_head}", clone.branch_at_head && "branch #{clone.branch_at_head}", clone.sha&.slice(0, 12)].compact
          [['clone', at.join(', ')]]
        end

        def candidate_lines(repo, entry)
          candidates = ::Pupgrade::Solve::Candidates.new(repo.dir, branchfile: @options[:branchfile], include_heads: true, fetch: @options[:fetch])
          list = candidates.for(entry, branch: @branch)
          candidates.warnings.each { |w| ::Pupgrade.logger.warn(w) }
          branch = @branch || branch_for(repo, entry)
          out = []
          out << ['branch', branch] if branch
          if list.is_a?(::Pupgrade::Solve::Candidates::Unsolvable)
            out << ['candidates', "none (#{list.reason})"]
          else
            newer = list.reject(&:current)
            out << ['candidates', newer.empty? ? 'none past the current version' : newer.map(&:ref).join(', ')]
          end
          out
        end

        def config_defaults
          surface_config_defaults.merge(branchfile: ::Pupgrade.config.dig('modules', 'branchfile')).compact
        end
      end
    end
  end
end
