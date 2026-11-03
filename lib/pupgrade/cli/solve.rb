require 'yaml'

require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'pupgrade/cli/table'
require 'pupgrade/config_keys'
require 'pupgrade/exclusions'
require 'driftless/control_repo'
require 'driftless/module_inventory'
require 'pupgrade/module_name'
require 'pupgrade/module_proposal'
require 'pupgrade/module_resolver'
require 'pupgrade/solve/candidates'
require 'pupgrade/solve/evidence'
require 'pupgrade/solve/graph'
require 'pupgrade/solve/solver'

module Pupgrade
  module CLI
    # `pupgrade solve`
    #
    # A version for every deployed git module, from the tags its clone
    # holds: one row per module that moves or stops short, a Puppetfile overlay
    # for `check --propose`, and the exclusions the result relies on. Exit 1
    # when any module is unresolved, or an unresolvable constraint is not
    # excluded.
    class Solve < Base
      include Table
      extend ::Pupgrade::ConfigKeys::DSL

      register_command name: 'solve', subcommand_of: Root
      desc 'Pick a version for every module along its tags, and write the proposed Puppetfile'

      config_key 'solve.order', type: :string, default: 'newest',
                 about: 'newest: move every module as far as its constraints allow; nearest: the fitting ' \
                        'version nearest the current one, driven by --bump'
      config_key 'solve.include_heads', type: :boolean, default: false,
                 about: 'Whether the tip of a tag-pinned module\'s tracking branch (modules.branchfile) is a candidate'
      config_key 'solve.compile_cache', type: :string, default: nil, example: 'pupgrade/cache/catalogs-alt',
                 about: 'A `compile` cache to read instead of compile.cache_dir: evidence of what the site uses, for --prune-unused'

      COLUMNS = %w[module current chosen candidates note].freeze

      # How a note's status word is coloured when stdout takes colour:
      # green for a module in the solved set, red for one nothing fits,
      # cyan for one the user placed; the part of each violation that
      # stands in the way is red.
      NOTE_STYLE = { solved: [:green], unresolved: [:red], lever: [:cyan] }.freeze

      def execute(argv)
        reject_extra_args!(argv)
        repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
        fatal!('solve requires --repo-dir (auto-detection did not supply it)', help: true) unless repo
        fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
        dir = compile_cache(repo)
        if @options[:prune_unused] && dir.nil?
          fatal!('solve: --prune-unused needs a `compile` cache: --compile-cache DIR, solve.compile_cache, or ' \
                 "compile.cache_dir (#{@options[:compile_cache_dir]}) once `compile` has written it", help: true)
        end

        inventory  = ::Driftless::ModuleInventory.new(repo.dir)
        candidates = ::Pupgrade::Solve::Candidates.new(repo.dir, branchfile: @options[:branchfile], include_heads: @options[:include_heads],
                                                                 fetch: @options[:fetch])
        evidence   = dir && ::Pupgrade::Solve::Evidence.new(dir)
        solver     = ::Pupgrade::Solve::Solver.new(operatingsystems: @options[:operatingsystems], requirements: @options[:requirements],
                                                   exclude: exclusions, order: @options[:order], bumps: @options[:bumps] || {},
                                                   holds: @options[:holds] || [], evidence: evidence, prune_unused: @options[:prune_unused])
        entries = ::Pupgrade::ModuleProposal.new(inventory, nil, ignore: @options[:ignore] || []).entries
        warn_drift(entries)
        ::Pupgrade.logger.notice("solve: reading the candidates of #{entries.size} module(s) from their clones#{' after fetching' if @options[:fetch]}")
        lists = entries.to_h { |e| [e.path, candidates.for(e)] }
        ::Pupgrade.logger.notice("solve: solving, #{@options[:order]} first#{'; pruning edges the catalogs show unused' if @options[:prune_unused]}")
        plan = solver.solve(entries, lists)
        log_warnings(inventory.warnings + candidates.warnings + plan.warnings.map { |w| "solve: #{w}" })

        shown = plan.choices.select { |c| @options[:all] || c.moved? || c.solved? || c.unresolved? || c.note == 'held at current' || !c.violations.empty? || !c.prior.empty? }
        print_table(COLUMNS, shown.map { |c| row(c) })
        print_explanations(plan) if @options[:explain]
        write_graph(plan.choices.select(&:refusal).select { |c| explained?(c) }.map(&:refusal)) if @options[:graph]
        plan.implicit.each { |i| ::Pupgrade.logger.warn("solve: #{i}: used, but not a declared dependency") }
        write_puppetfile(plan) if @options[:output]
        write_exclusions(plan) if @options[:write_exclusions]
        ::Pupgrade.logger.notice(summary(plan, evidence))
        exit((plan.choices.any? { |c| c.unresolved? || !c.prior.empty? }) ? 1 : 0)
      rescue ::Pupgrade::Solve::Solver::Error => e
        write_graph([e.refusal]) if @options[:graph] && e.refusal
        fatal!("solve: #{e.message}", 3)
      rescue ::Pupgrade::Solve::Evidence::Error, ::Pupgrade::ModuleResolver::Error, ::Pupgrade::Exclusions::Error, ArgumentError => e
        fatal!("solve: #{e.message}", 3)
      end

      protected

      def configure_parser(o)
        o.on('-d', '--repo-dir=DIR', 'Path to the control repo environment',
             "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        o.on('-o', '--output=PUPPETFILE', 'Write the moved modules as a Puppetfile overlay for `check --propose`') { |v| @options[:output] = v }
        o.on('--all', 'Show every module, not only those that move, stop short, are unresolved, or break a constraint',
             'that held at the current versions') { @options[:all] = true }
        o.on('--explain=MODULES', Array, 'After the table, the solver\'s whole reasoning for these modules (globs, or',
             'all): why a solved one stopped short, why an unresolved one fits nowhere') { |v| accumulate(:explain, v) }
        o.on('-g', '--graph-tree=FILE', 'Write the derivations as a mermaid flowchart, one tree per module that stopped',
             'short or fits nowhere (those --explain names, when given); - for stdout') { |v| @options[:graph] = v }
        o.on('--ignore=MODULES', Array,
             'Solve as if these modules were removed from the Puppetfile (globs on any spelling of the name,',
             'or the deploy path; comma-separated, repeatable). Unlike modules.exclude_modules, which leaves a',
             'module out of every check, this is a what-if: its dependents then miss it') { |v| accumulate(:ignore, v) }

        o.separator ''
        o.separator 'Candidates:'
        o.on('--order=ORDER', ::Pupgrade::Solve::Solver::ORDERS + ::Pupgrade::Solve::Solver::ORDER_ALIASES.keys, 'newest (default) or nearest (config: solve.order)') { |v| @options[:order] = v }
        o.on('--bump=MODULE[=REF]', 'Move MODULE to REF, or to its newest candidate; repeatable') { |v| bump(v) }
        o.on('--hold=MODULES', Array, 'Keep these modules at their current version; comma-separated, repeatable') { |v| accumulate(:holds, v) }
        o.on('--branchfile=FILE', 'The branch each tag-pinned module follows (config: modules.branchfile)') { |v| @options[:branchfile] = v }
        o.on('--[no-]include-heads', 'Make a tracking branch\'s tip a candidate (config: solve.include_heads)') { |v| @options[:include_heads] = v }
        o.on('--fetch', 'Fetch each clone\'s origin first, so new tags are seen') { @options[:fetch] = true }

        o.separator ''
        o.separator 'Pruning by what the site uses:'
        o.on('--compile-cache=DIR', 'The `compile` cache to read (config: solve.compile_cache, else compile.cache_dir)') { |v| @options[:compile_cache] = v }
        o.on('--prune-unused', 'Ignore dependency edges to and from modules the catalogs show unused') { @options[:prune_unused] = true }

        o.separator ''
        o.separator 'Exclusions, beyond the config\'s modules.exclude_* lists:'
        o.on('-x', '--exclusion-file=FILE', 'Read exclusions from FILE; repeatable') { |v| accumulate(:exclusion_files, [v]) }
        o.on('-w', '--write-exclusions-file=FILE', 'Write the exclusions the solution required') { |v| @options[:write_exclusions] = v }

        o.separator ''
        o.separator 'The solver (PubGrub) finds a set of versions in which every dependency range, the'
        o.separator 'Puppet requirement, and the operating systems of interest hold, each module as far'
        o.separator 'along its candidates as the set allows. A constraint no release of any module could meet is'
        o.separator '"unresolvable": kept from the solver, and on the row until an exclusion covers it. A hold'
        o.separator 'or a bump is a fact the solver cannot overrule. A module no version of which fits is'
        o.separator '"unresolved": kept at the candidate breaking the least, its constraints set aside. One short'
        o.separator 'of its newest candidate is "solved", and the note says which of its constraints is in the'
        o.separator 'way and what stands against it. Exits 1 when any module is unresolved, or any'
        o.separator 'unresolvable constraint is not excluded.'
      end

      private

      def row(choice)
        chosen = choice.chosen
        [choice.name, current_text(choice), chosen.current ? '(current)' : chosen.ref,
         (choice.candidates.size - 1).to_s, note(choice)]
      end

      # The status word coloured by outcome; a solved row says what stands in
      # its way. The part of each violation in the way is red, and so is the
      # label of an unresolvable constraint.
      def note(choice)
        style = if choice.unresolved? then :unresolved
                elsif ['bumped', 'held at current'].include?(choice.note) then :lever
                else :solved
                end
        text = paint(choice.note, *NOTE_STYLE.fetch(style))
        text += ": #{choice.why}" if choice.why
        text += ": #{violations_text(choice.violations)}" unless choice.violations.empty?
        text += "; #{paint('unresolvable', :red)}: #{violations_text(choice.prior)}" unless choice.prior.empty?
        text
      end

      def violations_text(violations)
        violations.map { |v| "#{v.text}, but #{paint(v.fault, :red)}" }.join('; ')
      end

      # The solver's reasoning for the modules asked about, in its own
      # words: why a solved module stopped short, or why nothing fits an
      # unresolved one.
      def print_explanations(plan)
        plan.choices.select { |c| explained?(c) }.each do |choice|
          puts ''
          puts "#{paint(choice.name, :bold)}: #{choice.chosen.ref} (#{[ note(choice) ].compact.uniq.join(', ')})"
          puts(choice.derivation ? choice.derivation.lines.map { |l| "  #{l}" }.join.chomp : paint('  nothing stood in the way', :dim))
        end
      end

      # Whether --explain names the module; every module when it is not given.
      def explained?(choice)
        globs = @options[:explain]
        globs.nil? || globs.include?('all') || ::Pupgrade::ModuleName.any?(globs, choice.name, choice.entry.metadata.name, File.basename(choice.entry.path))
      end

      # The derivations as one mermaid flowchart, to the file or stdout.
      def write_graph(refusals)
        text = ::Pupgrade::Solve::Graph.mermaid(refusals)
        if @options[:graph] == '-'
          puts text
        else
          File.write(File.expand_path(@options[:graph]), text)
          ::Pupgrade.logger.notice("solve: wrote #{refusals.size} tree(s) to #{File.expand_path(@options[:graph])}")
        end
      end

      def current_text(choice)
        entry = choice.entry
        version = entry.metadata.version
        declared = entry.declared
        return version.to_s if declared.nil?

        declared.git ? "#{declared.ref_type} #{declared.ref}" : "#{declared.version} (forge)"
      end

      # The moved modules as Puppetfile entries, replacing the current ones
      # at the same paths.
      def write_puppetfile(plan)
        lines = ["# Written by `pupgrade solve` #{Time.now.strftime('%Y-%m-%d %H:%M')}: an overlay for `pupgrade check --propose`", '']
        plan.choices.select(&:moved?).each do |c|
          declared = c.entry.declared
          lines << "mod '#{declared.name}',"
          lines << "  git: '#{declared.git}',"
          lines << "  install_path: '#{File.dirname(c.entry.path)}'," unless File.dirname(c.entry.path) == 'modules'
          lines << "  #{c.chosen.ref_type}: '#{c.chosen.ref}'"
        end
        File.write(File.expand_path(@options[:output]), lines.join("\n") + "\n")
        ::Pupgrade.logger.notice("solve: wrote #{File.expand_path(@options[:output])}")
      end

      # The pruned edges the result violates, and the constraints broken
      # before the solve that are still broken, in the config's lists.
      def write_exclusions(plan)
        lists = { 'dependencies' => plan.pruned.dup }
        plan.choices.flat_map(&:prior).each { |v| (lists[v.list] ||= []) << v.exclusion }
        data = { 'modules' => lists.sort.to_h { |l, globs| ["exclude_#{l}", globs.uniq] } }
        path = File.expand_path(@options[:write_exclusions])
        File.write(path, YAML.dump(data))
        ::Pupgrade.logger.notice("solve: wrote #{data['modules'].sum { |_, g| g.size }} exclusion(s) to #{path}")
      end

      def summary(plan, evidence)
        moved = plan.choices.count(&:moved?)
        short = plan.choices.count(&:solved?)
        open  = plan.choices.count(&:unresolved?)
        prior = plan.choices.sum { |c| c.prior.size }
        text  = "solve: #{moved} of #{plan.choices.size} module(s) move"
        text += %w[nearest oldest].include?(@options[:order]) ? ', each to its nearest fit' : ", #{short} solved short of newest"
        text += ", #{open} unresolved"
        text += "; #{prior} unresolvable constraint(s), not excluded#{' (--write-exclusions-file writes them)' unless @options[:write_exclusions]}" if prior.positive?
        text += "; #{plan.pruned.size} pruned edge(s) violated" if @options[:prune_unused]
        text += "; evidence from #{evidence.nodes} node(s)" if evidence
        text
      end

      # --compile-cache or the configured directory, else compile's when it
      # is there and the solve will read it.
      def compile_cache(repo)
        return File.expand_path(@options[:compile_cache], repo.dir) if @options[:compile_cache]
        return nil unless @options[:prune_unused]

        default = File.expand_path(@options[:compile_cache_dir], repo.dir)
        File.directory?(default) ? default : nil
      end

      def bump(text)
        name, ref = text.split('=', 2)
        fatal!("solve: --bump needs a module, got #{text.inspect}", help: true) if name.nil? || name.empty?
        (@options[:bumps] = (@options[:bumps] || {}).dup)[name] = ref
      end

      def accumulate(key, values)
        (@options[key] ||= []).concat(values)
      end

      # The config's modules.exclude_* lists, then each --exclusion-file's.
      def exclusions
        files = Array(@options[:exclusion_files]).map { |f| ::Pupgrade::Exclusions.read(File.expand_path(f)) }
        ::Pupgrade::Exclusions.merge(@options[:exclude] || {}, *files)
      end

      # A module whose clone is not at its declaration: the solve starts
      # from the clone, and the Puppetfile it writes holds only the moves,
      # so a deploy from that Puppetfile starts somewhere else.
      def warn_drift(entries)
        entries.select { |e| e.deployed == :differ && e.declared }.each do |e|
          declared = e.declared.git ? e.declared.ref : e.declared.version
          ::Pupgrade.logger.warn("solve: #{e.declared.name}: clone at #{e.found}, Puppetfile declares #{declared}; " \
                                 'the solve starts from the clone')
        end
      end

      def log_warnings(warnings)
        warnings.each { |w| ::Pupgrade.logger.warn(w) }
      end

      def config_defaults
        cfg = ::Pupgrade.config
        {
          operatingsystems: cfg.dig('modules', 'operatingsystems'),
          requirements:     cfg.dig('modules', 'requirements'),
          branchfile:       cfg.dig('modules', 'branchfile'),
          order:            cfg.dig('solve', 'order') || 'newest',
          include_heads:    cfg.dig('solve', 'include_heads') || false,
          compile_cache:     cfg.dig('solve', 'compile_cache'),
          compile_cache_dir: cfg.dig('compile', 'cache_dir') || 'pupgrade/cache/catalogs',
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
