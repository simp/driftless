require 'pupgrade/cli/base'
require 'pupgrade/cli/module_command'
require 'pupgrade/cli/impact'
require 'pupgrade/cli/surface'
require 'pupgrade/cli/table'
require 'driftless/module_inventory'
require 'pupgrade/impact/evidence'
require 'pupgrade/impact/usage'
require 'pupgrade/surface/diff'

module Pupgrade
  module CLI
    class ModuleCommand
      # `pupgrade module usage`
      #
      # What the site uses of one deployed module: one row per item of its
      # API surface, whether the compiled catalogs show it used, and where.
      # Exit 1 when nothing uses the module.
      class Usage < Base
        include Table
        include ModuleCommand::Shared
        include Surface::Shared
        include Impact::Shared

        register_command name: 'usage', subcommand_of: ModuleCommand
        positional '<module>'
        desc 'What the site uses of one deployed module: each API surface item, and where the compiled catalogs use it'

        COLUMNS  = %w[item used where].freeze
        SECTIONS = ::Pupgrade::Surface::Diff::SECTIONS

        def execute(argv)
          fatal!('module usage takes a module', help: true) unless argv.size == 1
          check_filters!
          repo      = control_repo!('module usage')
          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          entry     = inventory.find(argv.first)
          fatal!("module usage: no module #{argv.first.inspect} on the modulepath or in the Puppetfile", 3) unless entry
          name = entry.metadata.name || entry.declared&.name || File.basename(entry.path)

          evidence = load_evidence(repo)
          reader   = targets
          doc,     = reader.document(reader.resolve(File.join(repo.dir, entry.path)))
          rows     = ::Pupgrade::Impact::Usage.new(evidence).rows(doc, params: @options[:params])
          shown    = rows.select { |r| shown?(r) }
          print_table(COLUMNS, shown.map { |r| row(r) })

          items = rows.reject(&:param)
          used  = items.count(&:used?)
          ::Pupgrade.logger.notice("module usage: #{name}: #{used} of #{items.size} item(s) used; #{evidence.nodes.size} node(s) compiled")
          exit(used.positive? ? 0 : 1)
        rescue ::Pupgrade::Surface::Error, ::Pupgrade::Surface::Targets::Error, ::Pupgrade::Impact::Evidence::Error => e
          fatal!("module usage: #{e.message}", 3)
        end

        protected

        def configure_parser(o)
          declare_repo_option(o)
          o.on('--compile-cache=DIR', 'The `compile` cache to read (config: impact.compile_cache, else compile.cache_dir)') { |v| @options[:compile_cache] = v }
          o.on('--cache-dir=DIR', 'Where surface documents are kept (config: surface.cache_dir)') { |v| @options[:cache_dir] = v }
          o.on('--refresh', 'Extract the surface again, ignoring the cache') { @options[:refresh] = :all }
          o.on('--params', 'Also each class parameter: the nodes setting it, and those leaving its default') { @options[:params] = true }
          o.separator ''
          o.separator 'Row filters (comma-separated, repeatable; globs are case-insensitive):'
          o.on('--unused', 'Only what nothing uses') { @options[:unused] = true }
          o.on('--surfaces=KINDS', Array, "Only these surfaces (#{SECTIONS.join(', ')})") { |v| accumulate(:surfaces, v) }
          o.on('--names=GLOBS', Array, 'Only entries whose name matches (a parameter as CLASS::PARAM)') { |v| accumulate(:names, v) }
          o.separator ''
          o.separator 'A parameter is used when some node sets it. Exits 1 when nothing uses the module.'
        end

        private

        # @return [Impact::Evidence]
        def load_evidence(repo)
          dir = File.expand_path(@options[:compile_cache] || @options[:compile_cache_dir], repo.dir)
          fatal!("module usage: no compile cache at #{dir}; `compile` writes one", 3) unless File.directory?(dir)
          ::Pupgrade.logger.notice("module usage: reading catalogs under #{dir}")
          ::Pupgrade::Impact::Evidence.new(dir)
        end

        def row(usage)
          kind, namespace, leaf = usage.parts
          item = "#{paint(kind, :cyan)} #{paint(namespace, :cyan) unless namespace.empty?}#{leaf}"
          [item, usage.used? ? paint('yes', :green) : paint('no', :dim), usage.uses.map { |u| use_text(u, []) }.join('; ')]
        end

        def shown?(usage)
          (!@options[:unused] || !usage.used?) &&
            (Array(@options[:surfaces]).empty? || @options[:surfaces].include?(usage.section)) &&
            (Array(@options[:names]).empty? || @options[:names].any? { |g| File.fnmatch?(g, usage.item, File::FNM_CASEFOLD) })
        end

        def check_filters!
          unknown = Array(@options[:surfaces]) - SECTIONS
          fatal!("module usage: unknown surface #{unknown.first.inspect} (known: #{SECTIONS.join(', ')})", help: true) if unknown.any?
        end

        def accumulate(key, values)
          (@options[key] ||= []).concat(values)
        end

        def config_defaults
          cfg = ::Pupgrade.config
          surface_config_defaults.merge(compile_cache: cfg.dig('impact', 'compile_cache'),
                                        compile_cache_dir: cfg.dig('compile', 'cache_dir') || 'pupgrade/cache/catalogs').compact
        end
      end
    end
  end
end
