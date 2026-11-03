require 'json'
require 'yaml'

require 'pupgrade/cli/base'
require 'pupgrade/cli/catalog'
require 'pupgrade/cli/table'
require 'pupgrade/cli/compile_options'

module Pupgrade
  module CLI
    class Catalog
      # `pupgrade catalog resources`
      #
      # The resources of compiled catalogs, as `puppet resource` names
      # them: every one, or those of a type and title (each a glob), across
      # the nodes a certname glob matches; `File[/etc/motd]` as Puppet
      # prints a reference is taken too. Exit 1 when none matches.
      class Resources < Base
        include Table
        include CompileOptions

        register_command name: 'resources', subcommand_of: Catalog
        positional '[<type> [<title>] | <Type[title]>]', '<certglob>[,…]'
        desc 'List the resources of compiled catalogs, or show one by type and title'

        REFERENCE = /\A([A-Za-z*?][\w:*?]*)\[(.+)\]\z/.freeze

        FORMATS = %w[json yaml].freeze
        COLUMNS = %w[certname type title source].freeze

        # The types that are containers, not resources an agent manages.
        CONTAINERS = %w[Class Stage Node].freeze

        def execute(argv)
          fatal!('catalog resources takes [TYPE [TITLE]] CERTGLOB[,…]', help: true) if argv.empty? || argv.size > 3
          globs = argv.last.split(',')
          type, title = argv[0...-1]
          type, title = REFERENCE.match(type).captures if title.nil? && type&.match?(REFERENCE)
          repo = control_repo!('catalog resources')
          dir  = File.expand_path(@options[:cache_dir], repo.dir)
          names = nodes(dir, globs)
          fatal!("catalog resources: no compiled node matches #{argv.last.inspect} in #{dir}", 3) if names.empty?

          found = names.flat_map do |name|
            catalog = JSON.parse(File.read(File.join(dir, name, 'catalog.json')))
            catalog['resources'].select { |r| wanted?(r, type, title) }.map { |r| [name, r] }
          end
          if @options[:full]
            puts render(found.map { |name, r| r.merge('certname' => name) }) unless found.empty?
          elsif @options[:params]
            print_table(%w[certname type title parameters], found.map { |name, r| [name, r['type'], r['title'], (r['parameters'] || {}).keys.sort.join(', ')] })
          else
            print_table(COLUMNS, found.map { |name, r| row(name, r, repo) })
          end
          ::Pupgrade.logger.notice("catalog resources: #{found.size} resource(s) across #{names.size} node(s)")
          exit(found.empty? ? 1 : 0)
        rescue Errno::ENOENT, JSON::ParserError => e
          fatal!("catalog resources: #{e.message}", 3)
        end

        protected

        def configure_parser(o)
          o.on('-d', '--repo-dir=DIR', 'Path of deployed control repository (Default: `.`)') { |v| @options[:repo_dir] = v }
          o.on('--cache-dir=DIR', 'The compile cache to read (config: compile.cache_dir)') { |v| @options[:cache_dir] = v }
          o.on('--full', 'Print the matching resources whole instead of the table') { @options[:full] = true }
          o.separator 'A reference as Puppet prints one, File[/etc/motd], stands for TYPE TITLE.'
          o.on('--params', 'List each resource\'s parameter names instead of its source') { @options[:params] = true }
          o.on('--render-as=FORMAT', FORMATS, 'With --full: json (default) or yaml') { |v| @options[:format] = v }
        end

        private

        def nodes(dir, globs)
          return [] unless File.directory?(dir)

          Dir.children(dir).sort.select { |n| File.file?(File.join(dir, n, 'catalog.json')) && globs.any? { |g| File.fnmatch?(g, n, File::FNM_CASEFOLD) } }
        end

        # Type as `puppet resource` takes it, a glob in any case; the title
        # a glob.
        def wanted?(resource, type, title)
          return false if type && !File.fnmatch?(type, resource['type'].to_s, File::FNM_CASEFOLD)

          title.nil? || File.fnmatch?(title, resource['title'].to_s)
        end

        # The certname magenta, the type cyan, a container type (Class,
        # Stage, Node) dim, the title plain, the source file cyan with its
        # line dim.
        def row(name, resource, repo)
          type = resource['type'].to_s
          [paint(name, :magenta), paint(type, CONTAINERS.include?(type) ? :dim : :cyan), resource['title'].to_s, source_cell(repo, resource)]
        end

        def source_cell(repo, resource)
          return '' unless resource['file']

          file = paint(resource['file'].to_s.delete_prefix("#{repo.dir}/"), :cyan)
          resource['line'] ? "#{file}#{paint(":#{resource['line']}", :dim)}" : file
        end

        def render(value)
          (@options[:format] == 'yaml') ? YAML.dump(value) : JSON.pretty_generate(value)
        end

        def config_defaults
          { cache_dir: ::Pupgrade.config.dig('compile', 'cache_dir') || 'pupgrade/cache/catalogs' }
        end
      end
    end
  end
end
