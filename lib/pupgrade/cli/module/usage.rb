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

        # What a --used-by glob can be narrowed to, by prefix.
        USED_BY_KINDS = %w[node resource code path].freeze

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
          on_un(o, 'used', 'Only what something uses; --unused, what nothing uses') { |v| @options[:used] = v }
          o.on('--surfaces=KINDS', Array, "Only these surfaces (#{SECTIONS.join(', ')})") { |v| accumulate(:surfaces, v) }
          o.on('--item=GLOBS', Array, 'Only surface items with matching names (a parameter as CLASS::PARAM)') { |v| accumulate(:items, v) }
          o.on('--site=GLOBS', Array, 'Only items used from a code file matching') { |v| accumulate(:sites, v) }
          o.on('--used-by=GLOBS', Array, 'Only items with a use matching: node:, resource:, code:, or path: narrows the kind') { |v| accumulate(:used_by, v) }
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
          (@options[:used].nil? || @options[:used] == usage.used?) &&
            (Array(@options[:surfaces]).empty? || @options[:surfaces].include?(usage.section)) &&
            (Array(@options[:items]).empty? || @options[:items].any? { |g| File.fnmatch?(g, usage.item, File::FNM_CASEFOLD) }) &&
            (Array(@options[:sites]).empty? || @options[:sites].any? { |g| used_by?(usage, "path:#{g}") }) &&
            (Array(@options[:used_by]).empty? || @options[:used_by].any? { |g| used_by?(usage, g) })
        end

        # Whether any use of the item answers the glob: `node:` a certname,
        # `resource:` a Type[title], `code:` a call site as file:line,
        # `path:` a call site's file; without a prefix, any of them. The
        # brackets of a Type[title] are literal, not a character class.
        def used_by?(usage, glob)
          kind, sep, pattern = glob.partition(':')
          unless !sep.empty? && USED_BY_KINDS.include?(kind)
            kind    = nil
            pattern = glob
          end
          pattern = pattern.gsub(/[\[\]]/) { |c| "\\#{c}" }
          usage.uses.any? do |use|
            use.items.any? do |item|
              texts(use, item).any? { |k, text| (kind.nil? || kind == k) && File.fnmatch?(pattern, text, File::FNM_CASEFOLD) }
            end
          end
        end

        # @return [Array<Array(String, String)>] each kind the item answers
        #   to, with its text
        def texts(use, item)
          out = []
          out << ['node', item.certname] if item.certname
          return out if item.name.nil?
          return out << ['resource', item.name] if use.label == 'resources'

          out << ['code', item.name] << ['path', item.name.sub(/:\d+\z/, '')]
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
