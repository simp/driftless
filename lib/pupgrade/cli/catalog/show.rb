require 'json'
require 'yaml'

require 'pupgrade/cli/base'
require 'pupgrade/cli/catalog'
require 'pupgrade/cli/compile_options'
require 'pupgrade/cli/catalog/resources'

module Pupgrade
  module CLI
    class Catalog
      # `pupgrade catalog show`
      #
      # A compiled catalog, or its probes record, from the cache: whole, or
      # the part a key path names.
      class Show < Base
        include CompileOptions

        register_command name: 'show', subcommand_of: Catalog
        positional '[<keypath>]', '<certglob>[,…]'
        desc <<~'DESC'
          Show a compiled catalog (or its probes) from the cache

          A key path walks into the document: dotted keys, [n] for an array index,
          [Type[title]] for a resource (a list when either is a glob), `.` for the
          whole: resources[0].title, resources[File[/etc/motd]].parameters, leaks[0]
        DESC

        FORMATS = %w[json yaml].freeze

        def execute(argv)
          fatal!('catalog show takes [KEYPATH] CERTGLOB[,…]', help: true) if argv.empty? || argv.size > 2
          path, globs = (argv.size == 2) ? [argv[0], argv[1]] : ['.', argv[0]]
          repo = control_repo!('catalog show')
          dir  = File.expand_path(@options[:cache_dir], repo.dir)
          file = @options[:probes] ? 'compile.json' : 'catalog.json'
          names = nodes(dir, globs.split(','))
          fatal!("catalog show: no compiled node matches #{globs.inspect} in #{dir}", 3) if names.empty?

          values = names.to_h do |name|
            missing = File.join(dir, name, file)
            fatal!("catalog show: #{name} has no #{file}: its compile failed (#{File.join(dir, name, 'error.txt')})", 3) if !File.file?(missing) && File.file?(File.join(dir, name, 'error.txt'))
            doc = JSON.parse(File.read(missing))
            [name, walk(doc, path)]
          end
          values = values.transform_values { |v| keys_of(v) } if @options[:keys]
          puts render((values.size == 1) ? values.values.first : values)
          exit 0
        rescue Errno::ENOENT, JSON::ParserError => e
          fatal!("catalog show: #{e.message}", 3)
        rescue KeyError => e
          fatal!("catalog show: #{e.message}", 1)
        end

        protected

        def configure_parser(o)
          o.on('-d', '--repo-dir=DIR', 'Path of deployed control repository (Default: `.`)') { |v| @options[:repo_dir] = v }
          o.on('--cache-dir=DIR', 'The compile cache to read (config: compile.cache_dir)') { |v| @options[:cache_dir] = v }
          o.on('-p', '--probes', 'Show compile.json, the compile record, instead of catalog.json') { @options[:probes] = true }
          o.on('-k', '--keys', 'Show the keys at the path (or the size of an array) instead of the value') { @options[:keys] = true }
          o.on('--render-as=FORMAT', FORMATS, 'json (default) or yaml') { |v| @options[:format] = v }
        end

        private

        def nodes(dir, globs)
          return [] unless File.directory?(dir)

          Dir.children(dir).sort.select { |n| File.directory?(File.join(dir, n)) && globs.any? { |g| File.fnmatch?(g, n, File::FNM_CASEFOLD) } }
        end

        # @param path [String] "a.b[0].c", "resources[File[/etc/motd]].tag"; "." or
        #   "" for the document
        # @raise [KeyError] naming the part not there
        def walk(doc, path)
          return doc if path.strip.empty? || path == '.'

          steps(path).reduce(doc) do |node, part|
            if part.start_with?('[')
              raise KeyError, "#{path}: #{part} on something that is not a list" unless node.is_a?(Array)

              inner = part[1..-2]
              if (ref = Resources::REFERENCE.match(inner))
                resource(node, *ref.captures) { raise KeyError, "#{path}: no resource #{inner}" }
              elsif inner.match?(/\A\d+\z/)
                node.fetch(inner.to_i) { raise KeyError, "#{path}: no #{part} (#{node.size} entries)" }
              else
                raise KeyError, "#{path}: #{part} is neither an index nor a Type[title]"
              end
            else
              raise KeyError, "#{path}: #{part} on something that is not a map" unless node.is_a?(Hash)

              node.fetch(part) { raise KeyError, "#{path}: no key #{part.inspect}" }
            end
          end
        end

        # The path's keys and bracketed steps, a bracket closing where its
        # nesting does, so a title's dots and brackets stay in it.
        #
        # @return [Array<String>] "resources", "[File[/etc/a.conf]]", "[0]", ...
        # @raise [KeyError] when a bracket is left open
        def steps(path)
          parts = []
          depth = 0
          part  = +''
          path.each_char do |c|
            if depth.zero? && ['.', '['].include?(c)
              parts << part unless part.empty?
              part = +''
              next if c == '.'
            end
            part << c
            depth += 1 if c == '['
            depth -= 1 if c == ']'
            next unless depth.zero? && c == ']'

            parts << part
            part = +''
          end
          raise KeyError, "#{path}: a [ is not closed" unless depth.zero?

          parts << part unless part.empty?
          parts
        end

        # The resource a reference names exactly, else the list it matches
        # as globs; the type in any case, as `catalog resources` takes it.
        #
        # @yield when nothing matches
        def resource(list, type, title)
          list  = list.grep(Hash)
          exact = list.find { |r| r['type'].to_s.casecmp?(type) && r['title'].to_s == title }
          return exact if exact

          found = list.select { |r| File.fnmatch?(type, r['type'].to_s, File::FNM_CASEFOLD) && File.fnmatch?(title, r['title'].to_s) }
          found.empty? ? yield : found
        end

        def keys_of(value)
          case value
          when Hash  then value.keys
          when Array then "#{value.size} entries"
          else value.class.name.downcase
          end
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
