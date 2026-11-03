require 'json'

require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'pupgrade/cli/table'
require 'pupgrade/config_keys'
require 'driftless/codebase'
require 'driftless/control_repo'
require 'driftless/module_inventory'
require 'driftless/params_schema'
require 'driftless/params_schema/validate'
require 'pupgrade/module_proposal'
require 'pupgrade/surface'
require 'pupgrade/surface/diff'
require 'pupgrade/surface/targets'
require 'pupgrade/impact/analysis'
require 'pupgrade/impact/evidence'
require 'pupgrade/impact/history'

module Pupgrade
  module CLI
    # `pupgrade impact`
    #
    # What the site would feel from a proposed Puppetfile: for each module
    # it moves, the surface changes between the deployed version and the
    # proposed ref, each mapped to the nodes, resources, call sites, and
    # Hiera keys the evidence shows concerned. Exit 1 when any finding has
    # a use.
    class Impact < Base
      # What is shared with `module usage`: how a use reads in a table cell.
      module Shared
        # Certnames magenta, a resource's Type[title] in the given style,
        # a file cyan with its `:line` dimmed, and "and N more" in its
        # items' color, dimmed.
        #
        # @param use [Pupgrade::Impact::Uses::Use]
        # @param style [Array<Symbol>] the color of a resource's Type[title]
        def use_text(use, style)
          items = use.items.map do |item|
            name = if item.name.nil? then nil
                   elsif use.label == 'resources' then paint(item.name, *style)
                   else file_text(item.name)
                   end
            [name, item.certname && paint(item.certname, :magenta)].compact.join(' on ')
          end
          return "#{use.label}: #{items.join(', ')}" unless use.more.positive?

          more = use.items.any?(&:certname) ? %i[magenta dim] : [:dim]
          "#{use.label}: #{items.join(', ')} #{paint("and #{use.more} more", *more)}"
        end

        # A `path:line` with the path cyan and the line dimmed.
        def file_text(site)
          path, sep, line = site.rpartition(':')
          return paint(site, :cyan) if sep.empty? || line !~ /\A\d+\z/

          "#{paint(path, :cyan)}#{paint(":#{line}", :dim)}"
        end
      end

      include Table
      include Shared
      extend ::Pupgrade::ConfigKeys::DSL

      register_command name: 'impact', subcommand_of: Root
      positional '<puppetfile>'
      desc 'What a proposed Puppetfile would change for the site: surface changes mapped to their uses'

      config_key 'impact.compile_cache', type: :string, default: nil, example: 'pupgrade/cache/catalogs-alt',
                 about: 'A `compile` cache to read instead of compile.cache_dir: evidence of what each node uses'

      COLUMNS         = %w[module impact subject where detail].freeze
      SUMMARY_COLUMNS = %w[module from to commits findings used].freeze

      def execute(argv)
        reject_extra_args!(argv, max: 1)
        repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
        fatal!('impact requires --repo-dir (auto-detection did not supply it)', help: true) unless repo
        fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
        puppetfile = argv.first || @options[:propose]
        fatal!('impact needs the proposed Puppetfile', help: true) unless puppetfile
        check_kinds!

        inventory = ::Driftless::ModuleInventory.new(repo.dir)
        proposal  = ::Pupgrade::ModuleProposal.new(inventory, File.expand_path(puppetfile, repo.dir))
        changes   = proposal.changes.select { |c| c.to && c.from }
        log_warnings(inventory.warnings + proposal.warnings)
        ::Pupgrade.logger.notice("impact: #{puppetfile} moves #{changes.size} module(s)")
        evidence  = load_evidence(repo)
        ::Pupgrade.logger.notice("impact: reading the surfaces of #{changes.size} module(s) at both refs")
        surfaces  = surfaces_for(repo, inventory, proposal, changes)
        ::Pupgrade.logger.notice('impact: checking Hiera data against the proposed classes, then each module\'s history')
        data, lookups = surfaces.empty? ? [{}, {}] : hiera_references(repo)
        analysis = ::Pupgrade::Impact::Analysis.new(evidence: evidence, hiera: data, lookups: lookups)

        modules  = []
        findings = []
        surfaces.each do |change, (from, to)|
          diff  = ::Pupgrade::Surface::Diff.documents(from, to)
          found = analysis.findings(change.name, diff, to)
          ::Pupgrade.logger.info("impact: #{change.name}: #{diff.size} change(s), #{found.size} finding(s)")
          found.each { |f| ::Pupgrade.logger.debug("impact: #{change.name}: #{f.kind} #{f.subject}: #{f.where}") }
          entry = inventory.entries.find { |e| e.path == change.path }
          history = ::Pupgrade::Impact::History.between(File.join(repo.dir, change.path), entry.declared.ref.to_s, proposed_ref(change),
                                                        from_version: from.dig('module', 'version'), to_version: to.dig('module', 'version'))
          modules << [change, history, found]
          findings.concat(found)
        end
        shown = findings.select { |f| shown?(f) }

        if @options[:summary]
          print_table(SUMMARY_COLUMNS, modules.map { |c, h, f| summary_row(c, h, f.select { |x| shown?(x) }) })
        else
          print_table(COLUMNS, shown.map { |f| [f.module, kind_cell(f.kind), subject_cell(f.subject), where_cell(f), detail_cell(f)] })
          print_history(modules) if @options[:changelog] || @options[:gitlog]
        end
        ::Pupgrade.logger.notice("impact: #{modules.size} module(s) move; #{shown.count(&:used?)} finding(s) with a use, " \
                               "#{shown.count { |f| !f.used? }} without#{" (#{::Pupgrade::Ansi.enabled?($stderr) ? ::Pupgrade::Ansi.wrap('no catalogs; uses unknown', :red) : 'no catalogs; uses unknown'})" unless evidence}")
        exit(shown.any?(&:used?) ? 1 : 0)
      rescue ::Pupgrade::ModuleProposal::Error, ::Pupgrade::Surface::Error, ::Pupgrade::Surface::Targets::Error,
             ::Pupgrade::Impact::Evidence::Error => e
        fatal!("impact: #{e.message}", 3)
      end

      protected

      def configure_parser(o)
        o.on('-d', '--repo-dir=DIR', 'Path to the control repo environment',
             "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        o.on('-p', '--propose=PUPPETFILE', 'The proposed Puppetfile, in the form `check --propose` reads; the same as giving it first') { |v| @options[:propose] = v }
        o.on('--cache-dir=DIR', 'Where surface documents are kept (config: surface.cache_dir)') { |v| @options[:cache_dir] = v }
        o.on('--refresh', 'Extract the surfaces again, ignoring the cache') { @options[:refresh] = :all }
        o.on('--compile-cache=DIR', 'The `compile` cache to read (config: impact.compile_cache, else compile.cache_dir)') { |v| @options[:compile_cache] = v }
        o.on('--no-catalogs', 'Read no catalogs: every change is a finding with its use unknown') { @options[:no_catalogs] = true }

        o.separator ''
        o.separator 'Row filters (comma-separated, repeatable; globs are case-insensitive):'
        o.on('--modules=GLOBS', Array, 'Only modules whose name matches') { |v| accumulate(:modules, v) }
        o.on('--impacts=KINDS', Array, "Only these kinds (#{::Pupgrade::Impact::Analysis::KINDS.join(', ')})") { |v| accumulate(:kinds, v) }
        o.on('--all', 'Show findings nothing uses too') { @options[:all] = true }
        o.on('--skip-requoted', 'Hide a default change only in its quotes (\'100\' -> 100)') { @options[:skip_requoted] = true }

        o.separator ''
        o.separator 'Layout:'
        o.on('--summary', 'One row per moving module: refs, commits, findings') { @options[:summary] = true }
        o.on('--gitlog', 'After the table, each module\'s commits between the refs') { @options[:gitlog] = true }
        o.on('--changelog', 'After the table, each module\'s CHANGELOG sections for the versions crossed') { @options[:changelog] = true }

        o.separator ''
        o.separator '<puppetfile> is what `solve -o` wrote, or an overlay of your own. Surfaces are read'
        o.separator 'from the deployed module and from the proposed ref (through the clone when it has'
        o.separator 'the ref, else the remote), into the cache `surface` keeps, and reused from there.'
        o.separator 'Exits 1 when any finding has a use.'
      end

      private

      def load_evidence(repo)
        return nil if @options[:no_catalogs]

        dir = @options[:compile_cache]
        if dir.nil? && File.directory?(File.expand_path(@options[:compile_cache_dir], repo.dir))
          dir = @options[:compile_cache_dir]
        end
        return nil unless dir

        ::Pupgrade.logger.notice("impact: reading catalogs under #{File.expand_path(dir, repo.dir)}")
        ::Pupgrade::Impact::Evidence.new(File.expand_path(dir, repo.dir))
      end

      # The current and proposed surface of every git module the proposal
      # moves, keyed by the change.
      #
      # @return [Hash{ModuleProposal::Change => Array(Hash, Hash)}]
      def surfaces_for(repo, inventory, proposal, changes)
        reader = ::Pupgrade::Surface::Targets.new(repo_dir: repo.dir, cache_dir: @options[:cache_dir], refresh: @options[:refresh])
        changes.filter_map { |change|
          entry    = inventory.entries.find { |e| e.path == change.path }
          proposed = proposal.entries.find { |e| e.path == change.path }
          next unless entry&.declared&.git && proposed&.declared&.git

          clone = File.join(repo.dir, change.path)
          ref   = proposed_ref(change)
          ::Pupgrade.logger.info("impact: #{change.name}: surfaces at #{entry.declared.ref} and #{ref}")
          from, = reader.document(reader.resolve(clone))
          to,   = reader.document(ref_in?(clone, ref) ? reader.resolve("#{clone}:#{ref}") : reader.remote(proposed.declared.git, ref))
          [change, [from, to]]
        }.to_h
      end

      def ref_in?(clone, ref)
        found = system('git', '-C', clone, 'rev-parse', '--verify', '--quiet', "#{ref}^{commit}", out: File::NULL, err: File::NULL)
        ::Pupgrade.logger.trace("git -C #{clone} rev-parse --verify --quiet #{ref}^{commit} (does the clone have #{ref}): #{found ? 'yes' : 'no'}")
        found
      end

      def proposed_ref(change)
        change.to.to_s.sub(/\A(tag|branch|commit|ref) /, '')
      end

      # Hiera keys and lookups the proposed classes no longer answer, by the
      # class or class::param they name: driftless's validator run against a
      # schema of the current repo with the moving modules' classes replaced
      # by their proposed surfaces.
      # What the repo's data and code say about keys: every top-level Hiera
      # key to the files setting it, and every key some lookup() reads to
      # its call sites, each as "path:line".
      #
      # @return [Array(Hash, Hash)] data keys, lookups
      def hiera_references(repo)
        code   = ::Driftless::Codebase.load(repo.dir)
        corpus = code.corpus(repo_dir: repo.dir)
        data   = Hash.new { |h, k| h[k] = [] }
        corpus.data_files.each do |df|
          path = ::Driftless::ParamsSchema.relative(df.path, repo.dir)
          df.top_level_keys.each { |key, line| data[key] << "#{path}:#{line}" }
        end
        lookups = Hash.new { |h, k| h[k] = [] }
        (corpus.code_lookup_calls + corpus.data_lookup_calls).each do |lc|
          lookups[lc.key] << "#{::Driftless::ParamsSchema.relative(lc.file, repo.dir)}:#{lc.line}"
        end
        [data, lookups]
      rescue StandardError => e
        ::Pupgrade.logger.warn("impact: Hiera references not checked: #{e.message}")
        [{}, {}]
      end

      # How the verb of a change is colored. `module diff` colors its
      # verbs the same way.
      VERB_STYLE = { 'added' => [:green], 'removed' => [:red] }.freeze

      # Each use as {Shared#use_text} reads it, a resource in the detail's
      # verb color; a use unknown red.
      def where_cell(finding)
        return paint(finding.where, :red) if finding.uses.nil?

        style = verb_style(finding)
        finding.uses.map { |use| use_text(use, style) }.join('; ')
      end

      # The impact kind colored by its verb: a removal red, and an added
      # required parameter red, since it breaks callers; a change, or a
      # parameter that lives on in Hiera (`class-param-hiera-only`), yellow.
      def kind_cell(kind)
        paint(kind, kind.end_with?('-removed', '-added-required') ? :red : :yellow)
      end

      # The subject's namespace cyan and its name plain, split the way
      # `module diff` splits an item: a define or type before a space
      # ("concat::fragment target"), else everything up to the last `::`.
      def subject_cell(subject)
        head, space, tail = subject.partition(' ')
        return "#{paint("#{head} ", :cyan)}#{tail}" unless space.empty?
        return subject unless subject.include?('::')

        namespace, _, name = subject.rpartition('::')
        "#{paint("#{namespace}::", :cyan)}#{name}"
      end

      # "changed param type: Variant[…] -> Optional[…]": the verb colored
      # by what happened, and what it happened to in cyan.
      def detail_cell(finding)
        phrase, rest = finding.detail.split(': ', 2)
        verb, thing = phrase.split(' ', 2)
        head = [paint(verb, *verb_style(finding)), thing && paint(thing, :cyan)].compact.join(' ')
        rest ? "#{head}: #{rest}" : head
      end

      # The color of the detail's verb; an added required parameter breaks
      # callers, so it is red.
      def verb_style(finding)
        phrase = finding.detail.split(': ', 2).first
        phrase.start_with?('added required') ? [:red] : VERB_STYLE.fetch(phrase.split(' ', 2).first, [:yellow])
      end

      def summary_row(change, history, findings)
        [change.name, change.from.to_s, change.to.to_s, history.commits ? history.commits.size.to_s : '?',
         findings.size.to_s, findings.count(&:used?).to_s]
      end

      def print_history(modules)
        modules.each do |change, history, _|
          next unless glob_any?(@options[:modules], change.name)

          puts ''
          commits = history.commits ? "#{history.commits.size} commit(s)" : 'commits unknown'
          puts "#{change.name}: #{change.from} -> #{change.to}, #{commits}"
          if @options[:gitlog] && history.commits
            history.commits.each { |c| puts "  #{c}" }
          end
          if @options[:changelog]
            puts(history.changelog ? history.changelog.lines.map { |l| "  #{l}" }.join : '  (no CHANGELOG sections for the versions crossed)')
          end
        end
      end

      def shown?(finding)
        (@options[:all] || finding.used? || finding.where == 'use unknown') &&
          glob_any?(@options[:modules], finding.module) &&
          (Array(@options[:kinds]).empty? || @options[:kinds].include?(finding.kind)) &&
          !(@options[:skip_requoted] && finding.change.requoted?)
      end

      def glob_any?(globs, value)
        Array(globs).empty? || globs.any? { |g| File.fnmatch?(g, value, File::FNM_CASEFOLD) }
      end

      def check_kinds!
        unknown = Array(@options[:kinds]) - ::Pupgrade::Impact::Analysis::KINDS
        return if unknown.empty?

        fatal!("impact: unknown impact kind #{unknown.first.inspect} (known: #{::Pupgrade::Impact::Analysis::KINDS.join(', ')})", help: true)
      end

      def accumulate(key, values)
        (@options[key] ||= []).concat(values)
      end

      def log_warnings(warnings)
        warnings.each { |w| ::Pupgrade.logger.warn(w) }
      end

      def config_defaults
        cfg = ::Pupgrade.config
        {
          compile_cache:     cfg.dig('impact', 'compile_cache'),
          compile_cache_dir: cfg.dig('compile', 'cache_dir') || 'pupgrade/cache/catalogs',
          cache_dir:            cfg.dig('surface', 'cache_dir') || 'pupgrade/cache/api_surfaces',
        }.compact
      end
    end
  end
end
