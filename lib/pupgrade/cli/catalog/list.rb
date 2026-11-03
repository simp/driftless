require 'json'

require 'pupgrade/cli/base'
require 'pupgrade/cli/catalog'
require 'pupgrade/cli/table'
require 'pupgrade/cli/compile_options'
require 'pupgrade/compile/probe_record'
require 'pupgrade/certname_globs'

module Pupgrade
  module CLI
    class Catalog
      # `pupgrade catalog list`
      #
      # The compiles the cache holds: one row per node, from the compile
      # record and the catalog each compile wrote.
      class List < Base
        include Table
        include CompileOptions

        register_command name: %w[list ls], subcommand_of: Catalog
        desc 'List the compiled catalogs in the cache'

        COLUMNS = %w[certname resources classes warnings mocks leaks missing status compiled].freeze

        def execute(argv)
          reject_extra_args!(argv)
          repo = control_repo!('catalog list')
          dir  = File.expand_path(@options[:cache_dir], repo.dir)
          fatal!("catalog list: #{dir} is not there; `catalog compile` writes it", 3) unless File.directory?(dir)

          rows = nodes(dir).map { |name| row(dir, name) }.sort_by(&:first).map(&:last)
          print_table(COLUMNS, rows)
          ::Pupgrade.logger.notice("catalog list: #{rows.size} node(s) in #{dir}")
          exit 0
        end

        protected

        def configure_parser(o)
          o.on('-d', '--repo-dir=DIR', 'Path of deployed control repository (Default: `.`)') { |v| @options[:repo_dir] = v }
          o.on('--cache-dir=DIR', 'The compile cache to list (config: compile.cache_dir)') { |v| @options[:cache_dir] = v }
          o.on('--certname=GLOB[,…]', Array, 'Only nodes whose certname matches; !GLOB leaves its matches out') { |v| accumulate(:certnames, v) }
        end

        private

        # The node directories, narrowed by --certname.
        def nodes(dir)
          Dir.children(dir).select { |n| File.file?(File.join(dir, n, ::Pupgrade::Compile::ProbeRecord::FILENAME)) }.sort
            .select { |n| ::Pupgrade::CertnameGlobs.match?(@options[:certnames], n) }
        end

        # One node's cells, with the key that puts the rows in the order
        # `compile` ran them: by the factset's path, then certname.
        #
        # @return [Array(Array(String, String), Array<String>)] key, cells
        def row(dir, name)
          file    = File.join(dir, name, ::Pupgrade::Compile::ProbeRecord::FILENAME)
          probes  = ::Pupgrade::Compile::ProbeRecord.read(file)
          catalog = File.file?(File.join(dir, name, 'catalog.json')) ? JSON.parse(File.read(File.join(dir, name, 'catalog.json'))) : nil
          status  = (probes['status'] == 'ok') ? paint('ok', :green) : paint(probes['status'].to_s, :red)
          cells   = [name,
                     catalog ? catalog['resources'].size.to_s : '-',
                     catalog ? catalog['classes'].size.to_s : '-',
                     (Array(probes['warnings']).size + Array(probes['deprecations']).size).to_s,
                     Array(probes['mocks']).size.to_s, Array(probes['leaks']).size.to_s, Array(probes['missing']).size.to_s,
                     status, File.mtime(file).strftime('%Y-%m-%d %H:%M')]
          [[probes['factset'].to_s, name], cells]
        rescue ::Pupgrade::Compile::ProbeRecord::Error, JSON::ParserError => e
          [['', name], [name, '-', '-', '-', '-', '-', '-', paint('unreadable', :red), e.message.delete_prefix("#{file}: ")]]
        end

        def config_defaults
          { cache_dir: ::Pupgrade.config.dig('compile', 'cache_dir') || 'pupgrade/cache/catalogs' }
        end
      end
    end
  end
end
